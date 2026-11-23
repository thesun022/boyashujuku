import os
import secrets
from datetime import timedelta

import pymysql
from flask import Flask, abort, g, jsonify, render_template, request
from flask_wtf.csrf import CSRFError, CSRFProtect

from .auth import STAGE_LABELS, auth, hasher
from .db import close_db
from .management import management
from .workbench import workbench


def create_app(config=None):
    app = Flask(__name__)
    app.config.from_mapping(
        SECRET_KEY=os.environ.get("BOYA_SECRET_KEY"),
        DB_HOST=os.environ.get("BOYA_DB_HOST", "127.0.0.1"),
        DB_PORT=int(os.environ.get("BOYA_DB_PORT", "3306")),
        DB_NAME=os.environ.get("BOYA_DB_NAME", "boya_media_center"),
        DB_USER=os.environ.get("BOYA_DB_USER"),
        DB_PASSWORD=os.environ.get("BOYA_DB_PASSWORD"),
        SESSION_COOKIE_NAME="boya_session",
        SESSION_COOKIE_HTTPONLY=True,
        SESSION_COOKIE_SAMESITE="Lax",
        SESSION_COOKIE_SECURE=os.environ.get("BOYA_HTTPS", "0") == "1",
        SESSION_REFRESH_EACH_REQUEST=False,
        PERMANENT_SESSION_LIFETIME=timedelta(hours=8),
        MAX_CONTENT_LENGTH=32 * 1024,
        ASSET_ROOT=os.environ.get("BOYA_ASSET_ROOT") or os.path.join(app.instance_path, "assets"),
        ASSET_MAX_BYTES=int(os.environ.get("BOYA_VIDEO_MAX_MIB", "512")) * 1024 * 1024,
    )
    if config:
        app.config.update(config)
    if not app.config["SECRET_KEY"] or len(app.config["SECRET_KEY"]) < 32:
        raise RuntimeError("BOYA_SECRET_KEY must be configured with at least 32 characters.")
    if not app.config["DB_USER"] or app.config["DB_USER"].lower() == "root" or not app.config["DB_PASSWORD"]:
        raise RuntimeError("Configure BOYA_DB_USER and BOYA_DB_PASSWORD for a dedicated Web database account.")
    app.config["DUMMY_PASSWORD_HASH"] = hasher.hash(secrets.token_urlsafe(32))
    app.teardown_appcontext(close_db)

    @app.before_request
    def upload_limit():
        if request.endpoint == "management.api_write" and request.view_args == {"module": "assets", "action": "upload"}:
            request.max_content_length = max(app.config["ASSET_MAX_BYTES"], 20 * 1024 * 1024) + 65536

    app.register_blueprint(auth)

    @app.before_request
    def authorize_upload():
        if request.endpoint == "management.api_write" and request.view_args == {"module": "assets", "action": "upload"}:
            if g.identity is None:
                abort(401)
            if "REGISTER_ASSET" not in g.identity.permissions:
                abort(403)

    CSRFProtect(app)
    app.register_blueprint(workbench)
    app.register_blueprint(management)
    app.jinja_env.globals["review_stage_labels"] = STAGE_LABELS

    def error_response(status, message):
        if request.path.startswith("/api/"):
            return jsonify(error=message), status
        return render_template("error.html", status=status, message=message), status

    @app.errorhandler(CSRFError)
    def expired_form(_error):
        return error_response(400, "表单校验已失效，请刷新页面后重试。")

    messages = {400: "请求参数不正确。", 401: "请先登录。", 403: "你没有权限访问此功能。",
                404: "找不到该记录，或你无法访问。", 409: "数据发生冲突，请刷新后重试。",
                413: "请求内容超过允许大小。"}
    for status, message in messages.items():
        app.register_error_handler(status, lambda error, s=status, m=message: error_response(
            s, error.description if error.description != type(error).description else m
        ))

    @app.errorhandler(pymysql.MySQLError)
    def database_error(error):
        app.logger.error("MySQL operation failed (%s)", error.args[0])
        return error_response(503, "暂时无法连接数据库，请稍后重试。")

    @app.errorhandler(OSError)
    def storage_error(error):
        app.logger.error("Local I/O operation failed (%s)", error.errno)
        return error_response(503, "暂时无法读取或写入素材，请联系管理员检查文件目录。")

    @app.after_request
    def response_headers(response):
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["X-Frame-Options"] = "DENY"
        if request.endpoint != "static":
            response.headers["Cache-Control"] = "no-store"
        return response

    return app
