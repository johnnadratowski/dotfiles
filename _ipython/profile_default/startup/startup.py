# Stdlib Imports
import datetime
from decimal import Decimal
import sys
import time
import traceback
import os

import importlib
reload = importlib.reload

from functions import *

###########################
# Custom Imports
###########################

unavailable = []

try:
    import requests as rq
except:
    unavailable.append("Requests")

try:
    import numpy as np
except:
    unavailable.append("Numpy")

try:
    import pandas as pd
except:
    unavailable.append("Pandas")

try:
    import sqlalchemy as sqla
    import sqlalchemy.orm as orm
except:
    unavailable.append("SQLAlchemy")

try:
    import sshtunnel
except:
    unavailable.append("SSHTunnel")

if unavailable:
    print("The following libraries are unavailable:")
    for u in unavailable:
        print("\t%s" % u)
    print()



###########################
# Magic Defaults
###########################

_ip = get_ipython()
_ip.run_line_magic("autocall", "")
# _ip.run_line_magic("pylab", "")

###########################
# Custom Magic
###########################

# Example
#from IPython.core.magic import register_line_magic
#@register_line_magic('pasta')
#def paste_copies(line):
#    _ip.magics_manager.magics['line']['paste']()
#del paste_copies


###########################
# Local Script Import
###########################

_dbs = {}
_local_path = os.path.expanduser('~/local-startup/python/pythonrc.py')
if os.path.exists(_local_path):
    import importlib.util
    spec = importlib.util.spec_from_file_location("local", _local_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    if hasattr(module, '_dbs'):
        _dbs.update(module._dbs)

    for attr in dir(module):
        if not attr.startswith("_"):
            globals()[attr] = getattr(module, attr)


########################
# DB Functions
#######################

def tuple_sql(t):
    if len(t) == 1:
        only_entry = t[0]
        if isinstance(only_entry, str):
            return "('{}')".format(only_entry)
        else:
            return '({})'.format(only_entry)
    else:
        return str(t)


def query_db(sql, con, index_col=None, coerce_float=True, params=None, parse_dates=None, chunksize=None):
    if isinstance(con, str):
        con = sqla.create_engine(con)
    return pd.read_sql_query(sql,
                             con=con,
                             index_col=index_col,
                             coerce_float=coerce_float,
                             params=params,
                             parse_dates=parse_dates,
                             chunksize=chunksize)


def DB(name):
    db = _dbs[name]
    if not hasattr(db, 'query'):
        db = db()
        def query_db(sql, index_col=None, coerce_float=True, params=None, parse_dates=None, chunksize=None):
            return pd.read_sql_query(sql,
                                     con=db,
                                     index_col=index_col,
                                     coerce_float=coerce_float,
                                     params=params,
                                     parse_dates=parse_dates,
                                     chunksize=chunksize)
        db.query = query_db

        Session = orm.sessionmaker(bind=db)
        db.session = Session()

    return db

