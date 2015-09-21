import qt5_qtsql

const QSQLRECORD_H = "<QtSql/QSqlRecord>"

type
    QSqlRecordObj* {.final, header: QSQLRECORD_H, importc: "QSqlRecord".} = object

proc record*(query: QSqlQueryObj): QSqlRecordObj {.header: QSQLRECORD_H, importcpp: "record".}

proc count*(record: QSqlRecordObj): cint {.header: QSQLRECORD_H, importcpp: "count".}
proc fieldName*(record: QSqlRecordObj, index: cint): QStringObj {.header: QSQLRECORD_H, importcpp: "fieldName".}
proc value*(record: QSqlRecordObj, index: cint): QVariantObj {.header: QSQLRECORD_H, importcpp: "value".}
proc value*(record: QSqlRecordObj, name: cstring): QVariantObj {.header: QSQLRECORD_H, importcpp: "value".}
proc isNull*(record: QSqlRecordObj, index: cint): bool {.header: QSQLRECORD_H, importcpp: "isNull".}