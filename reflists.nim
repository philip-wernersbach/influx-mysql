# A reflist is a linked list of references that is manually memory managed. It is needed because
# the reference counting GC's are recursive, and so they overflow the stack when a list is really
# large. reflists degrade to regular linked lists when the selected GC is not a reference counting
# GC because the mark-and-sweep GC's do not overflow the stack for large lists.
#
# markAndSweep has been added to the list of GC's where reflists are enabled by default due to a
# compiler bug that makes the compiler unable to generate traversals for large linked lists.
when not defined(disablereflists) and (compileOption("gc", "refc") or compileOption("gc", "v2") or compileOption("gc", "markAndSweep")):
    type 
        SinglyLinkedRefListNodeObj[T] = tuple
            next: ptr SinglyLinkedRefListNodeObj[T]
            value: pointer

        SinglyLinkedRefListNode*[T] = ptr SinglyLinkedRefListNodeObj[T]

        SinglyLinkedRefListObj*[T] = tuple
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
        result[] = (next: nil, value: cast[pointer](value))

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
        result[] = (head: nil, tail: nil)

    proc prepend*[T](list: SinglyLinkedRefList[T] not nil, value: ref T) =
        var node = newSinglyLinkedRefListNode[T](value)
        
        node.next = list.head   
        list.head = node

        if list.tail == nil:
            list.tail = node

    proc appendAfter*[T](list: SinglyLinkedRefList[T] not nil, listNode: SinglyLinkedRefListNode[T] not nil, value: ref T) =
        var node = newSinglyLinkedRefListNode[T](value)

        node.next = listNode.next
        listNode.next = node

        if list.tail == listNode:
            list.tail = node

        if list.head == listNode:
            list.head = node

    iterator items*[T](list: SinglyLinkedRefList[T] not nil): ref T =
        var current = list.head

        while current != nil:
            yield cast[ref T](current.value)
            current = current.next

    iterator refListNodes*[T](list: SinglyLinkedRefList[T] not nil): SinglyLinkedRefListNode[T] not nil =
        var current = list.head

        while current != nil:
            yield current
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

    iterator nodes*[T](list: SinglyLinkedRefList[T] not nil): SinglyLinkedRefListNode[T] =
        for node in list[].nodes:
            yield node

proc append*[T](list: SinglyLinkedRefList[T] not nil, value: ref T) =
    var node = newSinglyLinkedRefListNode[T](value)

    if list.tail != nil:
        list.tail.next = node

    list.tail = node

    if list.head == nil:
        list.head = node
