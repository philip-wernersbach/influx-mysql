import qt5_qtsql

import qtimezone
import qttimespec

const QDATETIME_H = "<QtCore/QDateTime>"

type
    qint64* {.final, header: "<QtCore/QtGlobal>", importc: "qint64".} = clonglong
    QDateTimeObj* {.final, header: QDATETIME_H, importc: "QDateTime".} = object

proc newQDateTimeObj*(): QDateTimeObj {.header: QDATETIME_H, importcpp: "QDateTime".}
proc setMSecsSinceEpoch*(dateTime: var QDateTimeObj, msecs: qint64) {.header: QDATETIME_H, importcpp: "setMSecsSinceEpoch".}
proc setTimeSpec*(dateTime: var QDateTimeObj, timeSpec: QtTimeSpec) {.header: QDATETIME_H, importcpp: "setTimeSpec".} 

proc newQDateTimeObj*(msecs: qint64): QDateTimeObj =
    result = newQDateTimeObj()
    result.setMSecsSinceEpoch(msecs)

proc newQDateTimeObj*(msecs: qint64, timeSpec: QtTimeSpec): QDateTimeObj =
    result = newQDateTimeObj()
    result.setTimeSpec(timeSpec)
    result.setMSecsSinceEpoch(msecs)

proc currentQDateTimeUtc*(): QDateTimeObj {.header: QDATETIME_H, importcpp: "QDateTime::currentDateTimeUtc".}

proc toQStringObj*(dateTime: QDateTimeObj, format: cstring): QStringObj {.header: QDATETIME_H, importcpp: "toString".}
proc toMSecsSinceEpoch*(dateTime: QDateTimeObj): qint64 {.header: QDATETIME_H, importcpp: "toMSecsSinceEpoch".}

proc setTimeZone*(dateTime: QDateTimeObj, toZone: QTimeZoneObj) {.header: QDATETIME_H, importcpp: "setTimeZone".}
proc addMSecs*(a: var QDateTimeObj, b: qint64): QDateTimeObj {.header: QDATETIME_H, importcpp: "addMSecs".}

proc `<`*(a: QDateTimeObj, b: QDateTimeObj): bool {.header: QDATETIME_H, importcpp: "(# < #)".}
