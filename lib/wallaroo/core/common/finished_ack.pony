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
use "wallaroo_labs/mort"

trait CustomAction
  fun ref apply()

actor InitialFinishedAckRequester is FinishedAckRequester
  """
  Used when we are the initiator of a chain of finished ack requests
  """
  be receive_finished_ack(request_id: RequestId) =>
    ifdef debug then
      @printf[I32](("Received finished ack at InitialFinishedAckRequester. " +
        "This indicates the originator of a chain of finished ack requests " +
        "has received the final ack.\n").cstring())
    end
    None

class FinishedAckWaiter
  let upstream_request_id: RequestId
  let _upstream_producer: FinishedAckRequester
  let _idgen: RequestIdGenerator = _idgen.create()
  var _awaiting_finished_ack_from: SetIs[RequestId] =
    _awaiting_finished_ack_from.create()
  var _custom_action: (CustomAction ref | None) = None

  new create(upstream_request_id': RequestId,
    upstream_producer: FinishedAckRequester = InitialFinishedAckRequester)
  =>
    upstream_request_id = upstream_request_id'
    _upstream_producer = upstream_producer

  fun ref set_custom_action(custom_action: CustomAction) =>
    _custom_action = custom_action

  fun ref run_custom_action() =>
    match _custom_action
    | let ca: CustomAction => ca()
    end

  fun ref add_consumer_request(): RequestId =>
    let request_id: RequestId = _idgen()
    _awaiting_finished_ack_from.set(request_id)
    request_id

  fun ref unmark_consumer_request(request_id: RequestId) =>
    _awaiting_finished_ack_from.unset(request_id)

  fun should_send_upstream(): Bool =>
    _awaiting_finished_ack_from.size() == 0

  fun ref unmark_consumer_request_and_send(request_id: RequestId) =>
    @printf[I32]("!@ --awaiting before: %s\n".cstring(),
      _awaiting_finished_ack_from.size().string().cstring())
    _awaiting_finished_ack_from.unset(request_id)
    @printf[I32]("!@ --awaiting after: %s\n".cstring(),
      _awaiting_finished_ack_from.size().string().cstring())
    if should_send_upstream() then
      @printf[I32]("!@ should_send_upstream\n".cstring())
      _upstream_producer.receive_finished_ack(upstream_request_id)
    //!@
    else
      @printf[I32]("!@ not should_send_upstream\n".cstring())
    end

