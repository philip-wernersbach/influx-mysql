import qt5_qtsql

const QDATETIME_H = "<QtCore/QDateTime>"

type
    qint64* {.final, header: "<QtCore/QtGlobal>", importc: "qint64".} = clonglong
    QDateTimeObj* {.final, header: QDATETIME_H, importc: "QDateTime".} = object

proc newQDateTimeObj*(): QDateTimeObj {.header: QDATETIME_H, importcpp: "QDateTime".}
proc setMSecsSinceEpoch*(dateTime: var QDateTimeObj, msecs: qint64) {.header: QDATETIME_H, importcpp: "setMSecsSinceEpoch".}

proc newQDateTimeObj*(msecs: qint64): QDateTimeObj =
    result = newQDateTimeObj()
    result.setMSecsSinceEpoch(msecs)

proc toQStringObj*(dateTime: QDateTimeObj, format: cstring): QStringObj {.header: QDATETIME_H, importcpp: "toString".}
proc toMSecsSinceEpoch*(dateTime: QDateTimeObj): qint64 {.header: QDATETIME_H, importcpp: "toMSecsSinceEpoch".}