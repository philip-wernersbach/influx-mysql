import qt5_qtsql

import qdatetime

const QVARIANT_H = "<QtCore/QVariant>"

proc userType*(variant: QVariantObj): cint {.header: QVARIANT_H, importcpp: "userType".}

converter toBool*(variant: QVariantObj): bool {.header: QVARIANT_H, importcpp: "toBool"}
converter toFloat*(variant: QVariantObj): float64 {.header: QVARIANT_H, importcpp: "toFloat"}

converter toQDateTimeObj*(variant: QVariantObj): QDateTimeObj {.header: QVARIANT_H, importcpp: "toDateTime"}
