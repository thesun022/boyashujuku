"""Build a private MySQL instance for browser verification or a local demonstration."""

import argparse
import os
import secrets
import socket
import subprocess
import sys
import tempfile
import time
from getpass import getpass
from pathlib import Path

import pymysql
from waitress import serve

from boya_web import create_app
from boya_web.bootstrap import provision_account
from boya_web.db import connect


ROOT = Path(__file__).resolve().parents[1]
SCHEMA = "boya_media_center"
WEB_DB_USER = "boya_web_lab"
QA_DB_USER = "boya_web_lab_owner"
DEMO_ACCOUNTS = ("MINISTER", "CHIEF", "SECOND", "THIRD", "WRITER", "LAYOUT", "PHOTO-A", "PHOTO-B", "VIDEO", "FORMER")
SQL_ORDER = (
    "01_create_database.sql", "02_create_tables.sql", "03_constraints_indexes.sql",
    "05_create_views.sql", "06_create_triggers.sql", "06b_create_procedures.sql",
    "06c_security_roles.sql", "04_reference_data.sql", "04_initial_data.sql",
)


class Lab:
    def __init__(self, bin_directory):
        self.bin_directory = bin_directory
        self.path = Path(tempfile.mkdtemp(prefix="boya-web-lab-"))
        self.mysql_log = self.path / "mysql.err"
        self.pipe = "BoyaWeb" + secrets.token_hex(8)
        self.web_db_password = secrets.token_hex(32)
        self.qa_db_password = secrets.token_hex(32)
        self.secret_key = secrets.token_hex(32)
        self.server = None
        self.port = None

    def binary(self, name):
        return str(self.bin_directory / (name + ".exe"))

    def mysql_pipe(self, sql, *, database=None):
        arguments = [self.binary("mysql"), "--no-defaults", "--protocol=PIPE",
                     f"--socket={self.pipe}", "--user=root", "--batch", "--skip-column-names",
                     "--default-character-set=utf8mb4"]
        if database:
            arguments.append(f"--database={database}")
        return subprocess.run(arguments, input=sql, capture_output=True,
                              creationflags=subprocess.CREATE_NO_WINDOW, timeout=45)

    def start_server(self, *flags):
        self.server = subprocess.Popen(
            [self.binary("mysqld"), "--no-defaults", f"--datadir={self.path / 'data'}",
             f"--log-error={self.mysql_log}", "--skip-log-bin", "--mysqlx=OFF",
             "--innodb-buffer-pool-size=64M", *flags],
            creationflags=subprocess.CREATE_NO_WINDOW,
        )

    def wait_for(self, check):
        for _ in range(60):
            if self.server.poll() is not None:
                break
            if check():
                return
            time.sleep(0.2)
        raise RuntimeError(f"测试 MySQL 启动失败，请查看 {self.mysql_log}")

    def connect_admin(self):
        return connect("127.0.0.1", self.port, QA_DB_USER, self.qa_db_password, SCHEMA)

    def tcp_ready(self):
        try:
            self.connect_admin().close()
        except pymysql.MySQLError:
            return False
        return True

    def start(self, demo_password):
        print(f"隔离测试目录：{self.path}", flush=True)
        subprocess.run(
            [self.binary("mysqld"), "--no-defaults", "--initialize-insecure",
             f"--datadir={self.path / 'data'}", f"--log-error={self.mysql_log}"],
            check=True, creationflags=subprocess.CREATE_NO_WINDOW, timeout=60,
        )
        self.start_server("--skip-networking", "--named-pipe", f"--socket={self.pipe}")
        self.wait_for(lambda: self.mysql_pipe(b"SELECT 1;").returncode == 0)
        for name in (*SQL_ORDER, "07_test_database.sql", "11_web_auth.sql", "12_web_dashboard.sql",
                     "13_web_operations.sql", "14_workflow_corrections.sql"):
            result = self.mysql_pipe(
                (ROOT / "database" / name).read_bytes(),
                database=None if name == SQL_ORDER[0] else SCHEMA,
            )
            if result.returncode:
                raise RuntimeError(f"{name}: {result.stderr.decode('utf-8', errors='replace')}")
            if name == "07_test_database.sql":
                baseline = sum(line.startswith(b"PASS ") for line in result.stdout.splitlines())
                if baseline != 52:
                    raise RuntimeError(f"基础数据库断言数量异常：{baseline}")
                print("PASS 数据库基础断言 52 项", flush=True)

        # Only the private socket is enabled while provisioning credentials. SQL uses generated hex strings.
        setup = f"""
          CREATE USER '{WEB_DB_USER}'@'127.0.0.1' IDENTIFIED BY '{self.web_db_password}';
          GRANT 'boya_web_auth'@'%' TO '{WEB_DB_USER}'@'127.0.0.1';
          SET DEFAULT ROLE 'boya_web_auth'@'%' TO '{WEB_DB_USER}'@'127.0.0.1';
          CREATE USER '{QA_DB_USER}'@'127.0.0.1' IDENTIFIED BY '{self.qa_db_password}';
          GRANT SELECT,INSERT,UPDATE,DELETE,EXECUTE ON {SCHEMA}.* TO '{QA_DB_USER}'@'127.0.0.1';
          GRANT SHUTDOWN ON *.* TO '{QA_DB_USER}'@'127.0.0.1';
          ALTER USER 'root'@'localhost' IDENTIFIED BY '{secrets.token_hex(32)}';
          SHUTDOWN;
        """
        if self.mysql_pipe(setup.encode("ascii")).returncode:
            raise RuntimeError("隔离实例账号配置失败。")
        self.server.wait(timeout=20)
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            self.port = listener.getsockname()[1]
        self.start_server("--bind-address=127.0.0.1", f"--port={self.port}", "--skip-name-resolve")
        self.wait_for(self.tcp_ready)
        with self.connect_admin() as conn:
            for suffix in DEMO_ACCOUNTS:
                person_code = f"DEMO-{suffix}"
                provision_account(conn, person_code=person_code, username=person_code.lower(),
                                  password=demo_password, reset_password=True)
            provision_account(conn, person_code="DEMO-WEB-ADMIN", username="demo-web-admin",
                              display_name="示例管理员", password=demo_password, role="SYSTEM_ADMIN")

    def env(self):
        return {
            "BOYA_SECRET_KEY": self.secret_key,
            "BOYA_DB_HOST": "127.0.0.1",
            "BOYA_DB_PORT": str(self.port),
            "BOYA_DB_NAME": SCHEMA,
            "BOYA_DB_USER": WEB_DB_USER,
            "BOYA_DB_PASSWORD": self.web_db_password,
            "BOYA_ASSET_ROOT": str(self.path / "assets"),
            "BOYA_HTTPS": "0",
        }

    def close(self):
        if self.server is None or self.server.poll() is not None:
            return
        if self.port:
            try:
                with self.connect_admin() as conn, conn.cursor() as cursor:
                    cursor.execute("SHUTDOWN")
            except pymysql.MySQLError:
                pass
        else:
            self.mysql_pipe(b"SHUTDOWN;")
        try:
            self.server.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.server.terminate()
            self.server.wait(timeout=10)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--preview", action="store_true", help="运行仅本机可访问的演示服务")
    parser.add_argument("--port", type=int, default=8080, help="演示服务 HTTP 端口")
    parser.add_argument("--mysql-bin", type=Path, default=Path(r"E:\MySQL\sever\bin"))
    args = parser.parse_args()
    demo_password = getpass("为本次虚构账号设置密码（12 至 256 字符）：") if args.preview else secrets.token_urlsafe(24)
    if len(demo_password) < 12 or len(demo_password) > 256:
        parser.error("密码长度须为 12 至 256 字符。")
    lab = Lab(args.mysql_bin)
    try:
        lab.start(demo_password)
        if args.preview:
            os.environ.update(lab.env())
            print(f"本机演示：http://127.0.0.1:{args.port}/login", flush=True)
            print("演示账号包括 demo-writer、demo-layout、demo-photo-a、demo-video、demo-minister、demo-chief、demo-second、demo-third 和 demo-web-admin。", flush=True)
            serve(create_app({"TEMPLATES_AUTO_RELOAD": True}), host="127.0.0.1", port=args.port)
            return 0
        test_env = {
            **os.environ, **lab.env(),
            "BOYA_QA_DB_USER": QA_DB_USER,
            "BOYA_QA_DB_PASSWORD": lab.qa_db_password,
            "BOYA_QA_WEB_PASSWORD": demo_password,
            "BOYA_QA_ARTIFACTS": str(lab.path),
        }
        return subprocess.run(
            [sys.executable, "-X", "utf8", "-m", "pytest", "-q", "tests"],
            cwd=ROOT, env=test_env, check=False,
        ).returncode
    except KeyboardInterrupt:
        return 0
    finally:
        lab.close()


if __name__ == "__main__":
    raise SystemExit(main())
