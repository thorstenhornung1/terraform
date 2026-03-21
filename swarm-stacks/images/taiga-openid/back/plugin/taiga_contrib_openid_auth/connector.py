# Copyright (C) 2014-2017 Andrey Antukh <niwi@niwi.nz>
# Copyright (C) 2014-2017 Jesús Espino <jespinog@gmail.com>
# Copyright (C) 2014-2017 David Barragán <bameda@dbarragan.com>
# Copyright (C) 2014-2017 Alejandro Alonso <alejandro.alonso@kaleidos.net>
# Adapted for modern Django (4.x+) compatibility.
#
# AGPL-3.0 License

import requests

from collections import namedtuple
from urllib.parse import urljoin

from django.conf import settings
# Django 4.0+: ugettext_lazy removed, use gettext_lazy
from django.utils.translation import gettext_lazy as _

from taiga.base.connectors.exceptions import ConnectorBaseException
from taiga.base.exceptions import AuthenticationFailed


class OpenIDApiError(ConnectorBaseException):
    pass


######################################################
# Data
######################################################

CLIENT_ID = getattr(settings, "OPENID_CLIENT_ID", None)
CLIENT_SCOPE = getattr(settings, "OPENID_SCOPE", "openid info")
CLIENT_SECRET = getattr(settings, "OPENID_CLIENT_SECRET", None)
TOKEN_URL = getattr(settings, "OPENID_TOKEN_URL", None)
USER_URL = getattr(settings, "OPENID_USER_URL", None)
OPENID_FILTER = getattr(settings, "OPENID_FILTER", "")

ID_FIELD = getattr(settings, "OPENID_ID_FIELD", "sub")
USER_FIELD = getattr(settings, "OPENID_USERNAME_FIELD", "preferred_username")
NAME_FIELD = getattr(settings, "OPENID_FULLNAME_FIELD", "name")
EMAIL_FIELD = getattr(settings, "OPENID_EMAIL_FIELD", "email")
FILTER_FIELD = getattr(settings, "OPENID_FILTER_FIELD", None)

HEADERS = {"Accept": "application/json"}

AuthInfo = namedtuple("AuthInfo", ["access_token"])
User = namedtuple("User", ["id", "username", "full_name", "email", "groups"])


######################################################
# utils
######################################################


def _get(url: str, headers: dict) -> dict:
    response = requests.get(url, headers=headers)
    data = response.json()
    if response.status_code != 200:
        raise OpenIDApiError(
            {"status_code": response.status_code, "error": data.get("error", "")}
        )
    return data


def _post(url: str, params: dict, headers: dict) -> dict:
    response = requests.post(url, data=params, headers=headers)
    try:
        data = response.json()
    except Exception:
        raise OpenIDApiError(
            {
                "status_code": response.status_code,
                "error": "error from data not retrievable",
                "content": response.content,
            }
        )
    else:
        if response.status_code != 200 or ("error" in data):
            raise OpenIDApiError(
                {
                    "status_code": response.status_code,
                    "error": data.get("error", ""),
                    "content": response.content,
                }
            )
    return data


######################################################
# Simple calls
######################################################


def login(
    access_code: str,
    token: str,
    redirect_uri: str,
    client_id: str = CLIENT_ID,
    client_secret: str = CLIENT_SECRET,
    headers: dict = HEADERS,
):
    if not CLIENT_ID or not CLIENT_SECRET:
        raise OpenIDApiError(
            {
                "error_message": _(
                    "The OpenID Connect plugin isn't properly configured. "
                    "Please contact your sysadmin."
                )
            }
        )

    if token == "" or token is None:
        url = TOKEN_URL
        params = {
            "grant_type": "authorization_code",
            "code": access_code,
            "client_id": CLIENT_ID,
            "client_secret": CLIENT_SECRET,
            "redirect_uri": redirect_uri,
            "scope": CLIENT_SCOPE,
        }
        data = _post(url, params=params, headers=headers)
        return AuthInfo(access_token=data.get("access_token", None))
    else:
        return AuthInfo(access_token=token)


def get_user_profile(headers: dict = HEADERS):
    url = USER_URL
    data = _get(url, headers=headers)

    if FILTER_FIELD:
        userinfo_filter_claim = data.get(FILTER_FIELD, None)
        if userinfo_filter_claim is None:
            raise AuthenticationFailed(
                "OPENID_FILTER_CLAIM provided but '{}' not found in UserInfo".format(
                    FILTER_FIELD
                )
            )
        filter_allowed = set(OPENID_FILTER.split(","))
        if not filter_allowed & set(userinfo_filter_claim):
            raise AuthenticationFailed("User does not satisfy OPENID_FILTER")

    username = (
        data.get(USER_FIELD)
        or data.get("preferred_username")
        or data.get("full_name")
        or data.get("username")
        or data.get("email")
    )

    return User(
        id=data.get(ID_FIELD, None),
        username=username,
        full_name=data.get(NAME_FIELD, None),
        email=data.get(EMAIL_FIELD, None),
        groups=data.get("groups", []),
    )


######################################################
# Combined calls
######################################################


def me(access_code: str, token: str, redirect_uri: str) -> tuple:
    auth_info = login(access_code, token, redirect_uri)
    headers = HEADERS.copy()
    headers["Authorization"] = "Bearer {}".format(auth_info.access_token)
    user = get_user_profile(headers=headers)
    return user
