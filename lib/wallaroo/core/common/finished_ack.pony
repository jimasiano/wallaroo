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

interface CustomAction
  fun ref apply()

class FinishedAckWaiter
  let upstream_request_id: U64
  let _upstream_producer: FinishedAckRequester
  let _idgen: GenericRequestIdGenerator = _idgen.create()
  var _awaiting_finished_ack_from: Array[U64] = _awaiting_finished_ack_from.create()
  var _custom_action: (CustomAction ref | None) = None

  new create(upstream_request_id': U64, upstream_producer: FinishedAckRequester)
  =>
    upstream_request_id = upstream_request_id'
    _upstream_producer = upstream_producer

  fun ref set_custom_action(custom_action: CustomAction) =>
    _custom_action = custom_action

  fun ref run_custom_action() =>
    match _custom_action
    | let ca: CustomAction => ca()
    end

  fun ref add_consumer_request(): U64 =>
    let request_id: U64 = _idgen()
    _awaiting_finished_ack_from.push(request_id)
    request_id

  fun ref unmark_consumer_request(request_id: U64) =>
    try
      let idx =  _awaiting_finished_ack_from.find(request_id)?
      _awaiting_finished_ack_from.delete(idx)?
    else
      Fail()
    end

  fun should_send_upstream(): Bool =>
    _awaiting_finished_ack_from.size() == 0

  fun ref unmark_consumer_request_and_send(request_id: U64) =>
    unmark_consumer_request_and_send(request_id)
    if should_send_upstream() then
      _upstream_producer.receive_finished_ack(upstream_request_id)
    end

