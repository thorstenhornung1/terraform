# Copyright (C) 2014-2017 Andrey Antukh <niwi@niwi.nz>
# Copyright (C) 2014-2017 Jesús Espino <jespinog@gmail.com>
# Copyright (C) 2014-2017 David Barragán <bameda@dbarragan.com>
# Copyright (C) 2014-2017 Alejandro Alonso <alejandro.alonso@kaleidos.net>
# Adapted for modern Django (4.x+) compatibility.
#
# AGPL-3.0 License

from django.apps import AppConfig


class TaigaContribOpenidAuthAppConfig(AppConfig):
    name = "taiga_contrib_openid_auth"
    verbose_name = "Taiga contrib openid auth App Config"
    # Django 3.2+: default_auto_field avoids deprecation warning
    default_auto_field = "django.db.models.BigAutoField"

    def ready(self):
        from taiga.auth.services import register_auth_plugin
        from . import services
        register_auth_plugin("openid", services.openid_login_func)
