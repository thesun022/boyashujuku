import argparse
from getpass import getpass

from pymysql import MySQLError

from .auth import hasher
from .db import connect


def provision_account(connection, *, person_code, username, password, display_name=None,
                      role="MEMBER_ADMIN", reset_password=False):
    if not 1 <= len(person_code) <= 40 or not 1 <= len(username) <= 80 or not 12 <= len(password) <= 256:
        raise ValueError("人员编号或账号长度无效，密码必须为 12 到 256 个字符。")
    if display_name is not None and not 1 <= len(display_name) <= 100:
        raise ValueError("姓名长度必须为 1 到 100 个字符。")
    password_hash = hasher.hash(password)
    connection.begin()
    try:
        with connection.cursor() as cursor:
            cursor.execute("SELECT id FROM person WHERE person_code=%s FOR UPDATE", (person_code,))
            person = cursor.fetchone()
            if person is None:
                if reset_password or not display_name:
                    raise ValueError("人员编号不存在；创建人员时请提供姓名。")
                cursor.execute("INSERT INTO person(person_code,display_name) VALUES (%s,%s)",
                               (person_code, display_name))
                person_id = cursor.lastrowid
            else:
                person_id = person["id"]
            cursor.execute("SELECT id,username FROM account WHERE person_id=%s FOR UPDATE", (person_id,))
            account = cursor.fetchone()
            if reset_password:
                if account is None or account["username"] != username:
                    raise ValueError("人员与现有账号不匹配。")
                cursor.execute("UPDATE account SET password_hash=%s WHERE id=%s", (password_hash, account["id"]))
            else:
                if account:
                    raise ValueError("已有账号；如需替换密码，请明确指定 --reset-password。")
                cursor.execute(
                    "INSERT INTO account(person_id,username,password_hash,enabled) VALUES (%s,%s,%s,TRUE)",
                    (person_id, username, password_hash),
                )
                cursor.execute("INSERT INTO account_role(account_id,role_code) VALUES (%s,%s)",
                               (cursor.lastrowid, role))
        connection.commit()
    except (MySQLError, ValueError):
        connection.rollback()
        raise


def main():
    parser = argparse.ArgumentParser(description="在指定 MySQL 实例初始化 Web 账号。")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--db-user", required=True)
    parser.add_argument("--person-code", required=True)
    parser.add_argument("--username", required=True)
    parser.add_argument("--display-name")
    parser.add_argument("--role", default="SYSTEM_ADMIN",
                        choices=("SYSTEM_ADMIN", "MEMBER_ADMIN", "CONTRIBUTOR", "MANAGER", "CHIEF_EDITOR", "EXTERNAL_REVIEWER"))
    parser.add_argument("--reset-password", action="store_true")
    args = parser.parse_args()
    password = getpass("Web 账号新密码：")
    if password != getpass("再次输入 Web 密码："):
        parser.error("两次输入的密码不一致。")
    database_password = getpass("MySQL 管理账号密码：")
    try:
        with connect(args.host, args.port, args.db_user, database_password, "boya_media_center") as conn:
            provision_account(conn, person_code=args.person_code, username=args.username, password=password,
                              display_name=args.display_name, role=args.role, reset_password=args.reset_password)
    except ValueError as error:
        parser.exit(1, f"{error}\n")
    except MySQLError as error:
        parser.exit(1, f"MySQL 操作失败（{error.args[0]}）。\n")
    print("Web 账号凭据已保存。")


if __name__ == "__main__":
    main()
