import qt5_qtsql

const QSQLDATABASE_H = "<QtSql/QSqlDatabase>"

proc qSqlDatabaseRemoveDatabase*(connectionName: cstring) {.header: QSQLDATABASE_H, importcpp: "QSqlDatabase::removeDatabase(@)".}
