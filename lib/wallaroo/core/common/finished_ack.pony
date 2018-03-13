/*

Copyright 2017 The Wallaroo Authors.

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
 implied. See the License for the specific language governing
 permissions and limitations under the License.

*/

use "collections"
use "wallaroo/core/invariant"
use "wallaroo_labs/mort"

trait CustomAction
  fun ref apply()

actor InitialFinishedAckRequester is FinishedAckRequester
  """
  Used when we are the initiator of a chain of finished ack requests
  """
  let _step_id: StepId

  new create(step_id: StepId) =>
    _step_id = step_id

  be receive_finished_ack(request_id: RequestId) =>
    ifdef debug then
      // !@TODO: Remove "This step id"
      @printf[I32](("Received finished ack at InitialFinishedAckRequester. " +
        "This indicates the originator of a chain of finished ack requests " +
        "has received the final ack. Request id received: %s. This step id: %s\n").cstring(),
        request_id.string().cstring(), _step_id.string().cstring())
    end
    None

  be receive_finished_complete_ack(request_id: RequestId) =>
    None

  be try_finish_request_early(requester_id: StepId) =>
    None

actor EmptyFinishedAckRequester is FinishedAckRequester
  be receive_finished_ack(request_id: RequestId) =>
    None

  be receive_finished_complete_ack(request_id: RequestId) =>
    None

  be try_finish_request_early(requester_id: StepId) =>
    None

class val FinishedAckCompleteId
  """
  Every time we complete a messages finished acking phase, one worker will
  generate a FinishedAckCompleteId and broadcast messages telling every node
  that we are done with that phase. This id includes the id of the
  initiator of the request_finished_complete_ack messages and a seq_id that
  increments every time that initiator creates a new one for a new phase.
  """
  let initial_requester_id: StepId
  let seq_id: RequestId

  new val create(initial_requester_id': StepId, seq_id': RequestId) =>
    initial_requester_id = initial_requester_id'
    seq_id = seq_id'

  fun eq(other: FinishedAckCompleteId): Bool =>
    (initial_requester_id == other.initial_requester_id) and
      (seq_id == other.seq_id)

class FinishedAckWaiter
  // This will be 0 for data receivers, router registry, and boundaries
  let _step_id: StepId
  let _id_gen: RequestIdGenerator = _id_gen.create()

  //////////////////
  // Finished Acks
  //////////////////
  // Map from the requester_id to the request id it sent us
  let _upstream_request_ids: Map[StepId, RequestId] =
    _upstream_request_ids.create()
  // Map from request_ids we generated to the requester_id for the
  // original upstream request they're related to
  let _downstream_request_ids: Map[RequestId, StepId] =
    _downstream_request_ids.create()
  let _pending_acks: Map[StepId, SetIs[RequestId]] = _pending_acks.create()
  let _upstream_requesters: Map[StepId, FinishedAckRequester] =
    _upstream_requesters.create()
  let _custom_actions: Map[StepId, CustomAction] = _custom_actions.create()

  /////////////////
  // Complete Ack Requests
  // For determining that all nodes have acknowledged that this round of
  // messages finished acking is over.
  /////////////////
  var _complete_request_ids: Map[StepId, RequestId] =
    _complete_request_ids.create()
  let _pending_complete_acks: SetIs[RequestId] =
    _pending_complete_acks.create()
  let _upstream_complete_requesters: Map[StepId, FinishedAckRequester] =
    _upstream_complete_requesters.create()
  let _upstream_complete_request_ids: Map[StepId, RequestId] =
    _upstream_complete_request_ids.create()
  var _custom_complete_action: (CustomAction | None) = None

  // If this was part of a step that was migrated, then it should no longer
  // receive requests. This allows us to check that invariant.
  var _has_migrated: Bool = false

  new create(id: StepId = 0) =>
    _step_id = id

  fun ref migrated() =>
    """
    Indicates that an encapsulating step has been migrated to another worker.
    """
    _has_migrated = true

  fun ref initiate_request(initiator_id: StepId,
    custom_action: (CustomAction | None) = None)
  =>
    add_new_request(initiator_id, 0, InitialFinishedAckRequester(_step_id))
    match custom_action
    | let ca: CustomAction =>
      set_custom_action(initiator_id, ca)
    end

  fun ref add_new_request(requester_id: StepId, request_id: RequestId,
    upstream_requester': (FinishedAckRequester | None) = None,
    custom_action: (CustomAction | None) = None)
  =>
    let upstream_requester =
      match upstream_requester'
      | let far: FinishedAckRequester => far
      else
        EmptyFinishedAckRequester
      end

    // If _upstream_request_ids contains the requester_id, then we're
    // already processing a request from it.
    if not _upstream_request_ids.contains(requester_id) then
      _upstream_request_ids(requester_id) = request_id
      _upstream_requesters(requester_id) = upstream_requester
      _pending_acks(requester_id) = SetIs[RequestId]
      match custom_action
      | let ca: CustomAction =>
        set_custom_action(requester_id, ca)
      end
    else
      ifdef debug then
        @printf[I32]("Already processing a request from %s. Ignoring.\n"
          .cstring(), requester_id.string().cstring())
      end
      //!@
      upstream_requester.receive_finished_ack(request_id)
    end

  fun ref initiate_complete_request(
    custom_action: (CustomAction | None) = None): FinishedAckCompleteId
  =>
    _custom_complete_action = custom_action
    let new_req_id =
      try
        _complete_request_ids(_step_id)? + 1
      else
        1
      end
    _complete_request_ids(_step_id) = new_req_id
    FinishedAckCompleteId(_step_id, new_req_id)

  fun ref set_custom_action(requester_id: StepId, custom_action: CustomAction)
  =>
    _custom_actions(requester_id) = custom_action

  fun ref run_custom_action(requester_id: StepId) =>
    try
      _custom_actions(requester_id)?()
    else
      Fail()
    end

  fun ref add_consumer_request(requester_id: StepId,
    supplied_id: (RequestId | None) = None): RequestId
  =>
    let request_id =
      match supplied_id
      | let r_id: RequestId => r_id
      else
        _id_gen()
      end
    try
      _downstream_request_ids(request_id) = requester_id
      _pending_acks(requester_id)?.set(request_id)
    else
      Fail()
    end
    request_id

  fun already_added_request(requester_id: StepId): Bool =>
    _upstream_request_ids.contains(requester_id)

  // !@
  fun pending_request(): Bool =>
    _upstream_request_ids.size() > 0

  fun ref unmark_consumer_request(request_id: RequestId) =>
    //!@
    if not _downstream_request_ids.contains(request_id) then
      @printf[I32]("!@ Failing because no _downstream_request_id\n".cstring())
    else
      try
        let requester_id = _downstream_request_ids(request_id)?
        if not _pending_acks.contains(requester_id) then
          @printf[I32]("!@ Failing because no _pending_ack entry\n".cstring())
        end
      end
    end

    try
      // @printf[I32]("!@ unmark_consumer_request 1\n".cstring())
      let requester_id = _downstream_request_ids(request_id)?
      // @printf[I32]("!@ received ack for request_id %s (associated with requester %s). (reported from %s)\n".cstring(), request_id.string().cstring(), requester_id.string().cstring(), _step_id.string().cstring())
      // @printf[I32]("!@ unmark_consumer_request 2\n".cstring())
      let id_set = _pending_acks(requester_id)?
      ifdef debug then
        Invariant(id_set.contains(request_id))
      end
      id_set.unset(request_id)
      // @printf[I32]("!@ unmark_consumer_request 3\n".cstring())
      _downstream_request_ids.remove(request_id)?
      // @printf[I32]("!@ unmark_consumer_request COMPLETE\n".cstring())
      _check_send_run(requester_id)
    else
      @printf[I32]("!@ About to fail on %s\n".cstring(), _step_id.string().cstring())
      Fail()
    end

  fun ref try_finish_request_early(requester_id: StepId) =>
    // @printf[I32]("!@ try_finish_request_early\n".cstring())
    _check_send_run(requester_id)

  fun ref request_finished_complete_ack(
    complete_request_id: FinishedAckCompleteId,
    request_id: RequestId, requester_id: StepId,
    requester: FinishedAckRequester,
    custom_action: (CustomAction | None) = None): Bool
  =>
    """
    Return true if this is the first time we've seen this complete_request_id.
    """
    ifdef debug then
      Invariant(not _has_migrated)
    end

    let initial_requester_id = complete_request_id.initial_requester_id
    let seq_id = complete_request_id.seq_id

    //!@
    // if _upstream_complete_requesters.contains(requester_id) or _upstream_complete_request_ids.contains(requester_id) then
    //   @printf[I32]("!@ Already saw requester_id: %s at node %s\n".cstring(), requester_id.string().cstring(), _step_id.string().cstring())
    // end

    //!@
    ifdef debug then
      // Since a node should only send a request to its downstreams once during
      // a single request_finished_complete_ack phase, we should never see
      // the same upstream requester id twice in the same phase.
      Invariant(not _upstream_complete_requesters.contains(requester_id) and
        not _upstream_complete_request_ids.contains(requester_id))
    end
    _upstream_complete_requesters(requester_id) = requester
    _upstream_complete_request_ids(requester_id) = request_id
    //!@
    // if _upstream_complete_request_ids.contains(requester_id) then
    //   try
    //     _upstream_complete_request_ids(requester_id)?.push(request_id)
    //   else
    //     Fail()
    //   end
    // else
    //   let r_ids = Array[RequestId]
    //   r_ids.push(request_id)
    //   _upstream_complete_request_ids(requester_id) = r_ids
    // end

    match custom_action
    | let ca: CustomAction =>
      _custom_complete_action = ca
    end

    // We need to see if we have already handled this phase. If so, then
    // we return false. If this is the first time we've received this
    // FinishedAckCompleteId, then we clear our old finished ack data and
    // return true so that the encapsulating node can send requests
    // downstream. We should never send requests downstream more than
    // once for the same FinishedAckCompleteId.
    if _complete_request_ids.contains(initial_requester_id) then
      try
        let current = _complete_request_ids(initial_requester_id)?
        // @printf[I32]("!@ request_finished_complete_ack Current: %s, seq_id: %s reported from %s. Pending: %s, upstream_complete_requesters: %s, init: %s\n".cstring(), current.string().cstring(), seq_id.string().cstring(), _step_id.string().cstring(), _pending_complete_acks.size().string().cstring(), _upstream_complete_requesters.size().string().cstring(), initial_requester_id.string().cstring())
        if current < seq_id then
          ifdef debug then
            // We shouldn't be processing a new complete ack phase until
            // the last one is finished.
            Invariant(_pending_complete_acks.size() == 0)
          end
          _complete_request_ids(initial_requester_id) = seq_id
          _clear_finished_ack_data()
          true
        else
          // If we've already handled this complete_request_id then we
          // can immediately ack any new upstream requester since we know
          // we've forwarded the request to all our downstreams and that there
          // is one requester still waiting on our ack (which would prevent
          // an early termination of the algorithm).
          requester.receive_finished_complete_ack(request_id)
          try
            // Since we just acked this requester for this request_id, we need
            // to remove it from our upstream records.
            _upstream_complete_requesters.remove(requester_id)?
            _upstream_complete_request_ids.remove(requester_id)?

            //!@
            // _upstream_complete_request_ids(requester_id)?.pop()?
            // if _upstream_complete_request_ids(requester_id)?.size() == 0 then
            //   _upstream_complete_request_ids.remove(requester_id)?
            //   _upstream_complete_requesters.remove(requester_id)?
            // end
          else
            Fail()
          end
          false
        end
      else
        Fail()
        false
      end
    else
        // @printf[I32]("!@ request_finished_complete_ack Current: %s, seq_id: %s reported from %s. Pending: %s, upstream_complete_requesters: %s, init: %s\n".cstring(), USize(0).string().cstring(), seq_id.string().cstring(), _step_id.string().cstring(), _pending_complete_acks.size().string().cstring(), _upstream_complete_requesters.size().string().cstring(), initial_requester_id.string().cstring())
      ifdef debug then
        // We shouldn't be processing a new complete ack phase until
        // the last one is finished.
        Invariant(_pending_complete_acks.size() == 0)
      end
      _complete_request_ids(initial_requester_id) = seq_id
      _clear_finished_ack_data()
      true
    end

  fun ref add_consumer_complete_request(
    supplied_id: (RequestId | None) = None): RequestId
  =>
    let request_id =
      match supplied_id
      | let r_id: RequestId => r_id
      else
        _id_gen()
      end
    _pending_complete_acks.set(request_id)
    request_id

  fun ref unmark_consumer_complete_request(request_id: RequestId) =>
    if _pending_complete_acks.size() > 0 then
      // @printf[I32]("!@ unmark_consumer_complete_request() with %s pending at %s\n".cstring(), _pending_complete_acks.size().string().cstring(), _step_id.string().cstring())
      _pending_complete_acks.unset(request_id)
      if _pending_complete_acks.size() == 0 then
        _complete_request_is_done()
      end
    //!@
    // else
    //   @printf[I32]("!@ We shouldn't be acked right now!!!\n".cstring())
    //   Fail()
    end

  fun ref try_finished_complete_request_early() =>
    // @printf[I32]("!@ try_finished_complete_request_early\n".cstring())
    if _pending_complete_acks.size() == 0 then
      _complete_request_is_done()
    end

  fun ref _complete_request_is_done() =>
    // @printf[I32]("!@ ------ !!! _complete_request_is_done() at %s,  upstream_complete_requesters: %s!!! \n".cstring(), _step_id.string().cstring(), _upstream_complete_requesters.size().string().cstring())
    for (requester_id, requester) in _upstream_complete_requesters.pairs() do
      try
        //!@
        // for upstream_request_id in
        //   _upstream_complete_request_ids(requester_id)?.values()
        // do
          let upstream_request_id =
            _upstream_complete_request_ids(requester_id)?
          requester.receive_finished_complete_ack(upstream_request_id)
        // end
      else
        Fail()
      end
    end
    match _custom_complete_action
    | let ca: CustomAction =>
      ca()
      _custom_complete_action = None
    end
    _clear_complete_data()

  fun ref _clear_finished_ack_data() =>
    // @printf[I32]("!@ finished_ack CLEAR on %s\n".cstring(), _step_id.string().cstring())
    _pending_acks.clear()
    _downstream_request_ids.clear()
    _upstream_request_ids.clear()
    _upstream_requesters.clear()
    _custom_actions.clear()

  fun ref _clear_complete_data() =>
    _pending_complete_acks.clear()
    _upstream_complete_requesters.clear()
    _upstream_complete_request_ids.clear()
    _custom_complete_action = None

  //!@
  fun report_status(code: ReportStatusCode) =>
    match code
    //!@
    | FinishedAcksStatus =>
      var pending: USize = 0
      var requester_id: StepId = 0
      for (r_id, pa) in _pending_acks.pairs() do
        if pa.size() > 0 then
          requester_id = r_id
          pending = pending + 1
        end
      end
      // @printf[I32]("!@ waiting at %s on %s pending ack groups, for requester ids:\n".cstring(), _step_id.string().cstring(), pending.string().cstring())
      // if pending == 1 then
        // @printf[I32]("!@ %s waiting for one for requester id %s\n".cstring(), _step_id.string().cstring(), requester_id.string().cstring())
      // end
      // for p in _pending_acks.keys() do
      //   @printf[I32]("!@ %s (from %s)\n".cstring(), p.string().cstring(), _step_id.string().cstring())
      // end
    //!@
    | RequestsStatus =>
      @printf[I32]("!@ *| Pending complete acks: %s\n".cstring(), _pending_complete_acks.size().string().cstring())
      for pca in _pending_complete_acks.values() do
        @printf[I32]("!@ *| -- %s\n".cstring(), pca.string().cstring())
      end
    end

  fun ref _check_send_run(requester_id: StepId) =>
    try
      // @printf[I32]("!@ _pending_acks size: %s for requester_id %s (reported from %s). Listing pending acks:\n".cstring(), _pending_acks(requester_id)?.size().string().cstring(), requester_id.string().cstring(), _step_id.string().cstring())
      // for pending_ack in _pending_acks(requester_id)?.values() do
      //   @printf[I32]("!@ -- %s\n".cstring(), pending_ack.string().cstring())
      // end
      if _pending_acks(requester_id)?.size() == 0 then
        let upstream_request_id = _upstream_request_ids(requester_id)?
        _upstream_requesters(requester_id)?
          .receive_finished_ack(upstream_request_id)
        if _custom_actions.contains(requester_id) then
          _custom_actions(requester_id)?()
          _custom_actions.remove(requester_id)?
        end
      end
    else
      Fail()
    end
