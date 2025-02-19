// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

library RateChangeQueue {
    struct RateChange {
        uint256 rate;
        uint256 untilEpoch;
    }

    struct Queue {
        // Map from index to RateChange
        mapping(uint256 => RateChange) changes;
        uint256 head;
        uint256 tail;
    }

    function enqueue(Queue storage queue, uint256 rate, uint256 untilEpoch) internal {
        queue.changes[queue.tail] = RateChange(rate, untilEpoch);
        queue.tail++;
    }

    function dequeue(Queue storage queue) internal returns (RateChange memory) {
        require(queue.head < queue.tail, "Queue is empty");
        RateChange memory change = queue.changes[queue.head];
        delete queue.changes[queue.head];
        queue.head++;
        return change;
    }

    function peek(Queue storage queue) internal view returns (RateChange memory) {
        require(queue.head < queue.tail, "Queue is empty");
        return queue.changes[queue.head];
    }

    function isEmpty(Queue storage queue) internal view returns (bool) {
        return queue.head >= queue.tail;
    }

    function clear(Queue storage queue) internal {
        while (!isEmpty(queue)) {
            dequeue(queue);
        }
        queue.head = 0;
        queue.tail = 0;
    }

    function size(Queue storage queue) internal view returns (uint256) {
        return queue.tail - queue.head;
    }
}
