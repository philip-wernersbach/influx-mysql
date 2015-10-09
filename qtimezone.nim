const QTIMEZONE_H = "<QtCore/QTimeZone>"

type
    QTimeZoneObj* {.final, header: QTIMEZONE_H, importc: "QTimeZone".} = object

proc qTimeZoneUtc*(): QTimeZoneObj {.header: QTIMEZONE_H, importcpp: "QTimeZone::utc".}
