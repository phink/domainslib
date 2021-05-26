
module Ws_deque = Ws_deque.M

type mutex_condvar = {
  mutex: Mutex.t;
  condition: Condition.t
}

type waiting_status =
  | Waiting
  | Released of int

type 'a t = {
  mask: int;
  channels: 'a Ws_deque.t array;
  waiters: (waiting_status ref * mutex_condvar ) Chan.t;
  next_domain_id: int Atomic.t;
  recv_block_spins: int;
}

type dls_state = {
  mutable id: int;
  mutable steal_offsets: int array;
  rng_state: Random.State.t;
  mc: mutex_condvar;
}

let dls_key =
  Domain.DLS.new_key (fun () ->
    {
      id = -1;
      steal_offsets = Array.make 1 0;
      rng_state = Random.State.make_self_init ();
      mc = {mutex=Mutex.create (); condition=Condition.create ()};
    })

let rec log2 n =
  if n <= 1 then 0 else 1 + (log2 (n asr 1))

let make ?(recv_block_spins = 2048) n =
  let sz = Int.shift_left 1 ((log2 (n-1))+1) in
  assert ((sz >= n) && (sz > 0));
  assert (Int.logand sz (sz-1) == 0);
  { mask = sz - 1;
    channels = Array.init sz (fun _ -> Ws_deque.create ());
    waiters = Chan.make_unbounded ();
    next_domain_id = Atomic.make 0;
    recv_block_spins;
    }

let register_domain mchan =
  let id = Atomic.fetch_and_add mchan.next_domain_id 1 in
  assert(id < Array.length mchan.channels);
  id

let init_domain_state mchan dls_state =
  let id = (register_domain mchan) in
  dls_state.id <- id;
  dls_state.steal_offsets <- Array.init ((Array.length mchan.channels)-1) (fun i -> i+1);
  dls_state
  [@@inline never]

let get_local_id mchan =
  let dls_state = Domain.DLS.get dls_key in
  if dls_state.id >= 0 then dls_state.id
  else (init_domain_state mchan dls_state).id
  [@@inline]

let clear_local_state () =
  let dls_state = Domain.DLS.get dls_key in
  dls_state.id <- (-1)

let rec check_waiters mchan id =
  Domain.Sync.poll (); (* need to make sure we have a safepoint in here *)
  match Chan.recv_poll mchan.waiters with
    | None -> ()
    | Some (status, mc) ->
      (* avoid the lock if we possibly can *)
      match !status with
      | Released _ -> check_waiters mchan id
      | Waiting -> begin
        Mutex.lock mc.mutex;
        match !status with
        | Waiting ->
          begin
            status := Released id;
            Mutex.unlock mc.mutex;
            Condition.broadcast mc.condition
          end
        | Released _ ->
          begin
            (* this waiter is already released, it might have found something on a poll *)
            Mutex.unlock mc.mutex;
            check_waiters mchan id
          end
      end

let send mchan v =
  let id = (get_local_id mchan) in
  Ws_deque.push (Array.unsafe_get mchan.channels id) v;
  check_waiters mchan id

let rec recv_poll_loop mchan dls cur_offset =
  Domain.Sync.poll (); (* need to make sure we have a safepoint in here *)
  let offsets = dls.steal_offsets in
  let k = (Array.length offsets) - cur_offset in
  if k = 0 then raise Exit
  else begin
    let idx = cur_offset + (Random.State.int dls.rng_state k) in
    let t = Array.unsafe_get offsets idx in
    let channel = Array.unsafe_get mchan.channels (Int.logand (dls.id + t) mchan.mask) in
    try
      Ws_deque.steal channel
    with
      | Exit ->
        begin
          Array.unsafe_set offsets idx (Array.unsafe_get offsets cur_offset);
          Array.unsafe_set offsets cur_offset t;
          recv_poll_loop mchan dls (cur_offset+1)
        end
  end

let recv_poll mchan =
  Domain.Sync.poll (); (* need to make sure we have a safepoint in here *)
  let id = (get_local_id mchan) in
  try
    Ws_deque.pop (Array.unsafe_get mchan.channels id)
  with
    | Exit -> recv_poll_loop mchan (Domain.DLS.get dls_key) 0

let rec recv_poll_repeated mchan repeats =
  try
    recv_poll mchan
  with
    | Exit ->
      if repeats = 1 then raise Exit
      else begin
        Domain.Sync.cpu_relax ();
        recv_poll_repeated mchan (repeats - 1)
      end

let rec recv mchan =
  try
    recv_poll_repeated mchan mchan.recv_block_spins
  with
    Exit ->
      begin
        (* Didn't find anything, prepare to block:
         *  - enqueue our wait block in the waiter queue
         *  - check the queue again
         *  - go to sleep if our wait block has not been notified
         *  - when notified retry the recieve
         *)
        let dls_state = Domain.DLS.get dls_key in
        let mc = dls_state.mc in
        let status = ref Waiting in
        Chan.send mchan.waiters (status, mc);
        try
          let v = recv_poll mchan in
          (* need to check the status as might take an item
            which is not the one an existing sender has woken us
            to take *)
          Mutex.lock mc.mutex;
          begin match !status with
          | Waiting -> (status := Released dls_state.id; Mutex.unlock mc.mutex)
          | Released id ->
            (* we were simultaneously released from a sender;
              so need to release a waiter *)
            (Mutex.unlock mc.mutex; check_waiters mchan id)
          end;
          v
        with
          | Exit ->
            if !status = Waiting then begin
               Mutex.lock mc.mutex;
               while !status = Waiting do
                 Condition.wait mc.condition mc.mutex
               done;
               Mutex.unlock mc.mutex
            end;
            Domain.Sync.poll ();
            match !status with
            | Released id -> begin
              try
                Ws_deque.steal (Array.unsafe_get mchan.channels (Int.logand id mchan.mask))
              with
                Exit -> recv mchan
            end
            | Waiting -> failwith "impossible!"
      end
