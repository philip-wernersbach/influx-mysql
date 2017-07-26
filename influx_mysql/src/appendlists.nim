# appendlists.nim
# By Philip Wernersbach <philip.wernersbach@gmail.com>
#
# Licensed under the MIT License
# 
# MIT License
#
# Copyright (c) 2017 Philip Wernersbach
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# An AppendList is a seq of AppendListNodes. Each AppendListNode has a seq
# containing data elements. The data seq in an AppendListNode is a fixed size.
# When an element is appended to an AppendList, and the AppendListNode at the
# tail of the AppendList is at capacity, a new AppendListNode is allocated, and
# the element is inserted into the new AppendListNode's data seq.
#
# An AppendList is similar to an unrolled linked list, except all of the nodes
# are in a root seq, instead of a root linked list.
#
# An AppendList is useful when an append-only data structure is suitable, and
# the number of elements to be inserted is unknown. In these cases, an
# AppendList increases sequential locality while avoiding reallocating and
# moving the entire list when the list capacity is exceeded.

type
    AppendListNode*[T] = tuple
        capacity: int
        data: ref seq[T] not nil

    AppendList*[T] = tuple
        capacity: int
        nodes: seq[AppendListNode[T]] not nil

const NODES_GROWTH_FACTOR = 2
const MAX_NODES_GROWTH_LEN = 64

const DATA_GROWTH_FACTOR = NODES_GROWTH_FACTOR
const MAX_DATA_GROWTH_BYTES = 65536

proc initAppendListNode[T](capacity: Natural): AppendListNode[T] =
    result.capacity = capacity

    new(result.data)
    result.data[] = newSeqOfCap[T](capacity)

proc initAppendListOfCap*[T](capacity: Natural, segmentCapacity = Natural(MAX_NODES_GROWTH_LEN)): AppendList[T] =
    result.capacity = segmentCapacity
    result.nodes = cast[seq[AppendListNode[T]] not nil](newSeqOfCap[AppendListNode[T]](segmentCapacity))

    result.nodes.add(initAppendListNode[T](capacity))

proc append*[T](list: var AppendList[T], value: T) =
    let tail = list.nodes[list.nodes.len - 1]

    if tail.capacity > tail.data[].len:
        tail.data[].add(value)
    else:
        let oldLen = list.nodes.len

        list.nodes.setLen(min(oldLen * NODES_GROWTH_FACTOR, oldLen + MAX_NODES_GROWTH_LEN))
        list.nodes.setLen(oldLen + 1)

        let newTail = initAppendListNode[T](min(tail.capacity * DATA_GROWTH_FACTOR, MAX_DATA_GROWTH_BYTES div sizeof(T)))
        list.nodes[oldLen] = newTail

        newTail.data[].add(value)

iterator mitems*[T](list: var AppendList[T]): var T =
    for node in list.nodes.mitems:
        for value in node.data[].mitems:
            yield value

iterator items*[T](list: AppendList[T]): T =
    for node in list.nodes.items:
        for value in node.data[].items:
            yield value
