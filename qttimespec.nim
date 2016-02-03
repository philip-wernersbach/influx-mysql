const QT_H = "<QtCore/Qt>"

type
    QtTimeSpec* {.final, header: QT_H, importcpp: "Qt::TimeSpec".} = enum
        QtLocalTime = 0
        QtUtc = 1
        QtOffsetFromUtc = 2
