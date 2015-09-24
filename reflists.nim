when defined(enableReflists):
    type 
        SinglyLinkedRefListNodeObj[T] = tuple
            next: ptr SinglyLinkedRefListNodeObj[T]
            value: pointer

        SinglyLinkedRefListNode[T] = ptr SinglyLinkedRefListNodeObj[T]

        SinglyLinkedRefListObj[T] = tuple
            head: SinglyLinkedRefListNode[T]
            tail: SinglyLinkedRefListNode[T]

        SinglyLinkedRefList*[T] = ref SinglyLinkedRefListObj[T]

    proc newSinglyLinkedRefListNode[T](value: ref T): SinglyLinkedRefListNode[T] not nil =
        let p = alloc0(sizeof(SinglyLinkedRefListNode[T]))

        if p != nil:
            result = cast[SinglyLinkedRefListNode[T] not nil](p)
        else:
            raise newException(Exception, "Cannot allocate memory!")

        GC_ref(value)
        result[] = (next: nil, value: cast[pointer](value))

    proc finalizeSinglyLinkedRefList[T](list: SinglyLinkedRefList[T] not nil) =
        var current = list.head

        while current != nil:
            let value = cast[ref T](current.value)
            let next = current.next

            dealloc(current)
            GC_unref(value)
            current = next

    proc newSinglyLinkedRefList*[T](): SinglyLinkedRefList[T] not nil =
        new(result, finalizeSinglyLinkedRefList)
        result[] = (head: nil, tail: nil)

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
