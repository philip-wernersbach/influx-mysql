when not defined(disablereflists) and (compileOption("gc", "v2") or compileOption("gc", "refc")):
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

            free(current)
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
