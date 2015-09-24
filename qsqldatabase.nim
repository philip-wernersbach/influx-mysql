import qt5_qtsql

const QSQLDATABASE_H = "<QtSql/QSQlDatabase>"

proc qSqlDatabaseRemoveDatabase*(connectionName: cstring) {.header: QSQLDATABASE_H, importcpp: "QSqlDatabase::removeDatabase(@)".}