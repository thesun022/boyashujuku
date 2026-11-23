import pymysql
from flask import current_app, g
from pymysql.cursors import DictCursor


def connect(host, port, user, password, database, *, autocommit=True):
    return pymysql.connect(
        host=host,
        port=port,
        user=user,
        password=password,
        database=database,
        charset="utf8mb4",
        cursorclass=DictCursor,
        autocommit=autocommit,
        connect_timeout=5,
        read_timeout=10,
        write_timeout=10,
        init_command="SET SESSION time_zone = '+08:00'",
        binary_prefix=True,
    )


def get_db():
    if "db" not in g:
        config = current_app.config
        g.db = connect(
            config["DB_HOST"], config["DB_PORT"], config["DB_USER"],
            config["DB_PASSWORD"], config["DB_NAME"],
        )
    return g.db


def close_db(_error):
    connection = g.pop("db", None)
    if connection is not None:
        connection.close()


def query(sql, params=()):
    with get_db().cursor() as cursor:
        cursor.execute(sql, params)
        return cursor.fetchall()


def call(procedure, params):
    with get_db().cursor() as cursor:
        cursor.callproc(procedure, params)
        rows = cursor.fetchall() if cursor.description else []
        while cursor.nextset():
            pass
        return rows
