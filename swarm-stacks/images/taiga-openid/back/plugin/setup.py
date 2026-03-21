#!/usr/bin/env python
# -*- coding: utf-8 -*-
# Adapted from robrotheram/taiga-contrib-openid-auth
# Simplified: removed versiontools dependency (Python 2 era)

from setuptools import setup, find_packages

setup(
    name="taiga-contrib-openid-auth",
    version="6.0.0",
    description="Taiga plugin for OpenID Connect authentication",
    long_description="",
    keywords="taiga, openid, auth, plugin",
    author="Robert Fletcher",
    url="https://github.com/robrotheram/taiga-contrib-openid-auth",
    license="AGPL",
    include_package_data=True,
    packages=find_packages(),
    install_requires=[],
    classifiers=[
        "Programming Language :: Python",
        "Development Status :: 4 - Beta",
        "Framework :: Django",
        "Intended Audience :: Developers",
        "License :: OSI Approved :: GNU Affero General Public License v3",
        "Operating System :: OS Independent",
        "Topic :: Internet :: WWW/HTTP",
    ],
)
