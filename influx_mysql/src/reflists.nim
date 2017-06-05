# relists.nim
# By Philip Wernersbach <philip.wernersbach@gmail.com>
#
# Licensed under the MIT License
# 
# MIT License
#
# Copyright (c) 2016-2017 Philip Wernersbach
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

# A reflist is a linked list of references that is manually memory managed. It is needed because
# the reference counting GC's are recursive, and so they overflow the stack when a list is really
# large. reflists degrade to regular linked lists when the selected GC is not a reference counting
# GC because the mark-and-sweep GC's do not overflow the stack for large lists.

when not defined(disablereflists) and (compileOption("gc", "refc") or compileOption("gc", "v2")):
    type 
        # There is no need for this to be an object, but it has to be an object
        # to work around a Nim compiler bug. nim-lang/Nim#5891
        SinglyLinkedRefListNodeObj[T] = object
            next: ptr SinglyLinkedRefListNodeObj[T]
            value: pointer

        SinglyLinkedRefListNode[T] = ptr SinglyLinkedRefListNodeObj[T]

        SinglyLinkedRefListObj[T] = tuple
            head: SinglyLinkedRefListNode[T]
            tail: SinglyLinkedRefListNode[T]

        SinglyLinkedRefList*[T] = ref SinglyLinkedRefListObj[T]

    proc newSinglyLinkedRefListNode[T](value: ref T): SinglyLinkedRefListNode[T] not nil =
        let p = create(SinglyLinkedRefListNodeObj[T])

        if p != nil:
            result = cast[SinglyLinkedRefListNode[T] not nil](p)
        else:
            raise newException(Exception, "Cannot allocate memory!")

        GC_ref(value)
        result.value = cast[pointer](value)

    proc finalizeSinglyLinkedRefList*[T](list: SinglyLinkedRefList[T] not nil) =
        var current = list.head
        list.head = nil
        list.tail = nil

        while current != nil:
            let value = cast[ref T](current.value)
            let next = current.next
            current.next = nil

            dealloc(current)
            GC_unref(value)
            current = next

    template removeAll*[T](list: SinglyLinkedRefList[T] not nil) =
        list.finalizeSinglyLinkedRefList

    proc newSinglyLinkedRefList*[T](): SinglyLinkedRefList[T] not nil =
        new(result, finalizeSinglyLinkedRefList)

    proc prepend*[T](list: SinglyLinkedRefList[T] not nil, value: ref T) =
        var node = newSinglyLinkedRefListNode[T](value)
        
        node.next = list.head
        list.head = node

        if list.tail == nil:
            list.tail = node

    iterator items*[T](list: SinglyLinkedRefList[T] not nil): ref T =
        var current = list.head

        while current != nil:
            yield cast[ref T](current.value)
            current = current.next
else:
    import lists

    type 
        SinglyLinkedRefListNode[T] = SinglyLinkedNode[ref T]
        SinglyLinkedRefList*[T] = ref SinglyLinkedList[ref T]

    proc newSinglyLinkedRefList*[T](): SinglyLinkedRefList[T] not nil =
        new(result)
        result[] = initSinglyLinkedList[ref T]()

    proc newSinglyLinkedRefListNode[T](value: ref T): SinglyLinkedRefListNode[T] =
        result = newSinglyLinkedNode[ref T](value)

    template removeAll*[T](list: SinglyLinkedRefList[T] not nil) = 
        discard

    iterator items*[T](list: SinglyLinkedRefList[T] not nil): ref T =
        for item in list[].items:
            yield item

proc append*[T](list: SinglyLinkedRefList[T] not nil, value: ref T) =
    var node = newSinglyLinkedRefListNode[T](value)

    if list.tail != nil:
        list.tail.next = node

    list.tail = node

    if list.head == nil:
        list.head = node
