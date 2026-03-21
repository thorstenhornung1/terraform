# Copyright (C) 2014-2017 Andrey Antukh <niwi@niwi.nz>
# Copyright (C) 2014-2017 Jesús Espino <jespinog@gmail.com>
# Copyright (C) 2014-2017 David Barragán <bameda@dbarragan.com>
# Copyright (C) 2014-2017 Alejandro Alonso <alejandro.alonso@kaleidos.net>
# Adapted for modern Django (4.x+) compatibility.
#
# AGPL-3.0 License

from django.db import transaction as tx
from django.db import IntegrityError
# Django 4.0+: ugettext removed, use gettext
from django.utils.translation import gettext as _

from django.apps import apps

from taiga.base.utils.slug import slugify_uniquely
from taiga.base import exceptions as exc
from django.conf import settings
from taiga.auth.services import send_register_email
from taiga.auth.services import make_auth_response_data, get_membership_by_token
from taiga.auth.signals import user_registered as user_registered_signal

from . import connector

PUBLIC_REGISTER_ENABLED = getattr(settings, "PUBLIC_REGISTER_ENABLED", False)


@tx.atomic
def openid_register(
    username: str,
    email: str,
    full_name: str,
    openid_id: int,
    token: str = None,
):
    auth_data_model = apps.get_model("users", "AuthData")
    user_model = apps.get_model("users", "User")

    try:
        # openid user association exist?
        auth_data = auth_data_model.objects.get(key="openid", value=openid_id)
        user = auth_data.user
    except auth_data_model.DoesNotExist:
        try:
            # Is a user with the same email as the openid user?
            user = user_model.objects.get(email=email)
            auth_data_model.objects.create(
                user=user, key="openid", value=openid_id, extra={}
            )
        except user_model.DoesNotExist:
            if PUBLIC_REGISTER_ENABLED:
                # Create a new user
                username_unique = slugify_uniquely(
                    username, user_model, slugfield="username"
                )
                user = user_model.objects.create(
                    email=email, username=username_unique, full_name=full_name
                )
                auth_data_model.objects.create(
                    user=user, key="openid", value=openid_id, extra={}
                )

                send_register_email(user)
                user_registered_signal.send(sender=user.__class__, user=user)
            else:
                raise exc.IntegrityError(
                    _(
                        "Sorry, was unable to locate user and registrations "
                        "have been disabled by the Administrator"
                    )
                )

    if token:
        membership = get_membership_by_token(token)

        try:
            membership.user = user
            membership.save(update_fields=["user"])
        except IntegrityError:
            raise exc.IntegrityError(
                _("This user is already a member of the project.")
            )

    return user


def openid_login_func(request):
    code = request.DATA.get("code", None)
    token = request.DATA.get("token", None)
    accessToken = request.DATA.get("access_token", None)
    redirect_uri = request.DATA.get("url", None)

    user_info = connector.me(code, accessToken, redirect_uri)
    user = openid_register(
        username=user_info.username,
        email=user_info.email,
        full_name=user_info.full_name,
        openid_id=user_info.id,
        token=token,
    )
    # Sync admin status from OIDC groups
    OPENID_ADMIN_GROUP = getattr(settings, "OPENID_ADMIN_GROUP", None)
    if OPENID_ADMIN_GROUP and hasattr(user_info, "groups"):
        is_admin = OPENID_ADMIN_GROUP in (user_info.groups or [])
        if user.is_superuser != is_admin or user.is_staff != is_admin:
            user.is_superuser = is_admin
            user.is_staff = is_admin
            user.save(update_fields=["is_superuser", "is_staff"])

    data = make_auth_response_data(user)
    return data
