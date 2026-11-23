import secrets
from dataclasses import dataclass
from functools import wraps
from hashlib import sha256

from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerificationError
from flask import Blueprint, abort, current_app, g, redirect, render_template, request, session, url_for

from .db import call


auth = Blueprint("auth", __name__)
hasher = PasswordHasher()
POSITION_LABELS = {"CHIEF": "主编", "MINISTER": "部长", "MEMBER": "部员"}
STAGE_LABELS = {"MINISTER": "部长初审", "CHIEF": "主编审核", "SECOND": "二审", "THIRD": "三审"}


@dataclass(frozen=True)
class Identity:
    account_id: int
    person_id: int
    username: str
    display_name: str
    roles: dict
    permissions: frozenset
    titles: tuple


def token_digest(token):
    return sha256(token.encode("ascii")).digest()


def identity_from_rows(rows):
    first = rows[0]
    roles = {row["role_code"]: row["role_label"] for row in rows if row["role_code"]}
    permissions = frozenset(row["permission_code"] for row in rows if row["permission_code"])
    titles = []
    position = POSITION_LABELS.get(first["position_code"])
    if position:
        titles.append(position)
    if "REVIEW" in permissions:
        stages = (first["review_stages"] or "").split(",")
        titles.extend(label for stage, label in (("SECOND", "二审人"), ("THIRD", "三审人")) if stage in stages)
    if "MANAGE_MEMBER" in permissions:
        titles.append("管理员")
    if not titles:
        titles.extend(roles.values())
    return Identity(first["account_id"], first["person_id"], first["username"],
                    first["display_name"], roles, permissions, tuple(titles))


@auth.before_app_request
def load_identity():
    g.identity = None
    if request.endpoint == "static":
        return
    token = session.get("auth_token")
    if token:
        rows = call("sp_web_read_session", (token_digest(token),))
        if rows:
            g.identity = identity_from_rows(rows)
        else:
            session.clear()


def login_required(view):
    @wraps(view)
    def protected(*args, **kwargs):
        if g.identity is None:
            if request.path.startswith("/api/"):
                abort(401)
            return redirect(url_for("auth.login"))
        return view(*args, **kwargs)
    return protected


def require(permission):
    def decorate(view):
        @login_required
        @wraps(view)
        def protected(*args, **kwargs):
            if permission not in g.identity.permissions:
                abort(403)
            return view(*args, **kwargs)
        return protected
    return decorate


@auth.route("/login", methods=["GET", "POST"])
def login():
    if g.identity:
        return redirect(url_for("workbench.home"))
    if request.method == "GET":
        return render_template("login.html")

    username = request.form.get("username", "").strip()
    password = request.form.get("password", "")
    if not username or len(username) > 80 or not password or len(password) > 256:
        return render_template("login.html", error="请输入有效的账号和密码。", username=username[:80]), 400

    rows = call("sp_web_subject", (username,))
    account = rows[0] if rows else None
    verified_hash = account["password_hash"] if account else current_app.config["DUMMY_PASSWORD_HASH"]
    try:
        verified = hasher.verify(verified_hash, password)
    except (VerificationError, InvalidHashError):
        verified = False
    if account and account["enabled"] and verified:
        token = secrets.token_urlsafe(32)
        result = call("sp_web_open_session", (account["account_id"], verified_hash, token_digest(token)))
        if result[0]["created"]:
            session.clear()
            session["auth_token"] = token
            session.permanent = True
            return redirect(url_for("workbench.home"))
    return render_template("login.html", error="账号或密码不正确，或账号已停用。", username=username), 401


@auth.post("/logout")
def logout():
    token = session.get("auth_token")
    if token:
        call("sp_web_close_session", (token_digest(token),))
    session.clear()
    return redirect(url_for("auth.login"))
