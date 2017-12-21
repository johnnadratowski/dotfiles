"""
Contains python data structures
"""

import copy
import csv
import json
import subprocess
import tempfile

import func


class DynamicObject(object):
    """
    Object that does not throw exceptions when working with attributes that it does not
    currently contain.  Can specify a default for attributes that do not exist.
    """

    def __init__(self, default=None, **kwargs):
        self._default = default
        for k, v in kwargs.iteritems():
            setattr(self, k, v)

    def __getattr__(self, item):
        return self._default

    def __delattr__(self, item):
        try:
            delattr(self, item)
        except AttributeError:
            pass


O = DynamicObject


class AttrDict(dict):
    """
    Dictionary class that allows for dot notation when accessing members.
    If dict contains sub-dicts, those dicts will be converted to AttrDict
    so that the sub members can be accessed using dot notation as well.
    Example: dict1.dict2.value
    """

    def __init__(self, initial=None, dict_default=None, **kwargs):
        super(AttrDict, self).__setattr__('_dict_default', dict_default)
        super(AttrDict, self).__init__(initial or {}, **kwargs)

    def __getattr__(self, attr):
        try:
            return self[attr]
        except KeyError:
            return self._dict_default if '_dict_default' in self.__dict__ else None

    def __setitem__(self, key, value):
        if type(value) == dict:
            # Make so sub-dicts can be accessed using dot notation
            value = AttrDict(value)
        super(AttrDict, self).__setitem__(key, value)

    def __setattr__(self, key, value):
        if key in dir(self):
            super(AttrDict, self).__setattr__(key, value)
        else:
            self.__setitem__(key, value)

    def __delattr__(self, item):
        if item in dir(self):
            super(AttrDict, self).__delattr__(item)
        else:
            self.__delitem__(item)

    def add_member(self, name, value):
        """
        To get around default setattr behavior to add a member such as a method to this class,
        you can call this method.
        """
        super(AttrDict, self).__setattr__(name, value)


D = AttrDict


class Table(object):
    """
    Table models a lean data table.  Supports filtering, mapping, and joins.
    """

    def __init__(self, data, columns=None):
        self.columns = columns
        self._raw_data = data
        if not func.is_list_type(data):
            data = [data]

        if not data:
            return

        if func.is_list_type(data[0]):
            if not columns:
                raise Exception(
                    "Headers must be specified if passing a list of data")

            self._data = func.list_to_dict(columns, data)
        elif isinstance(data[0], dict):
            if not columns:
                self.columns = list(data[0].keys())

            self._data = [self._initialize_row(row) for row in data]
        else:
            raise Exception("Data type %s not supported for a row",
                            type(data[0]))

    @staticmethod
    def from_csv(f):
        is_path = False
        if isinstance(f, str):
            is_path = True
            f = open(f, mode='r')
        reader = csv.DictReader(f)
        table = Table([x for x in reader], reader.fieldnames)
        if is_path:
            f.close()
        return table

    @staticmethod
    def from_json(f):
        is_path = False
        if isinstance(f, str):
            is_path = True
            f = open(f, mode='r')
        data = json.load(f)
        if data:
            table = Table(data, list(data[0].keys()))
        else:
            table = Table()
        if is_path:
            f.close()
        return table

    @staticmethod
    def from_clipboard(self):
        data = subprocess.check_output(
            'pbpaste', env={'LANG': 'en_US.UTF-8'}).decode('utf-8')
        with tempfile.NamedTemporaryFile() as t:
            t.write(data)

        try:
            return Table.from_json(t.name)
        except:
            return Table.from_csv(t.name)

    def to_dicts(self):
        return copy.copy(self._data)

    def to_lists(self):
        return func.dict_to_list(self.columns, self._data)

    def _initialize_row(self, row):
        return func.take(row, *self.columns)

    def filter(self, fn):
        return Table(filter(fn, self._data), columns=self.columns)

    def map(self, fn):
        return Table(map(fn, self._data), columns=self.columns)

    def group(self, *columns):
        return self._group(self._data, self.unique(*columns), *columns)

    def _group(self, data, unique_data, columns):
        if not columns:
            return copy.copy(data)

        output = {}
        for unique in unique_data[0]:
            output[unique] = self._group(
                [d for d in data
                 if d[columns[0]] == unique], unique_data[1:], columns[1:])

    def unique(self, *columns):
        return [list(set(self[col]) for col in columns)]

    def aggregate(self, *group, **agg):
        data = [self._data]
        if group:
            data = func.flatten_dict(self.group(*group))

        table_data = []
        for d in data:
            output = func.take(d[0], *group)
            for col, fn in agg.items():
                output[col] = fn(col, func.take(d, col).values())

            table_data += output

        return Table(table_data, self.columns)

    def sort(self, cmp=None, key=None, reverse=False):
        output = sorted(
            copy.copy(self._data), cmp=cmp, key=key, reverse=reverse)
        return Table(output, self.columns)

    def join(self, table, left_on, right_on, how='left', default=None):
        if not table or not left_on or not right_on:
            raise Exception(
                "Missing arguments to join. Table, left_on, and right_on must have values."
            )
        if not len(left_on) == len(right_on):
            raise Exception(
                "Left on and right on args to join must be same length.")
        if isinstance(left_on, str):
            left_on = [left_on]
        if isinstance(right_on, str):
            right_on = [right_on]
        if any(l not in self.columns for l in left_on):
            raise Exception("Left on join field not in columns: " +
                            ", ".join(self.columns))
        if any(r not in table.columns for r in right_on):
            raise Exception("Right on join field not in columns: " +
                            ", ".join(table.columns))

        data = []
        for left in self._data:
            for right in table._data:
                matches = all(left[left_on[i]] == right[right_on[i]]
                              for i in range(len(left_on)))
                if how == 'inner':
                    if matches:
                        new = self._join_column(left, right)
                        data.append(new)
                elif how == 'left':
                    if matches:
                        new = self._join_column(left, right)
                    else:
                        new = self._join_empty_column(table.columns, default,
                                                      left)
                    data.append(new)
                elif how == 'outer':
                    if matches:
                        new = self._join_column(left, right)
                        data.append(new)
                    else:
                        new = self._join_empty_column(table.columns, default,
                                                      left)
                        data.append(new)
                        new = self._join_empty_column(
                            self.columns, default, right, suffix='right')
                        data.append(new)

        new_cols = copy.copy(self.columns)
        for right_col in table.columns:
            if right_col in new_cols:
                right_col = "_right"
            new_cols.append(right_col)

        return Table(data, new_cols)

    def _join_empty_column(self, columns, default, row, suffix="left"):
        new = copy.copy(row)
        for column in columns:
            if column in new:
                column += "_" + suffix
            new[column] = default
        return new

    def _join_column(self, left, right):
        new = copy.copy(left)
        for k, v in right.items():
            if k in left:
                k += "_right"
            new[k] = v
        return new

    def __getitem__(self, item):
        if callable(item):
            return [copy.copy(item(d)) for d in self._data]
        elif isinstance(item, str):
            if item not in self.columns:
                raise Exception("Table does not have column: " + item)
            return [copy.copy(d[item]) for d in self._data]
        elif isinstance(item, int):
            return copy.copy(self._data[item])
        elif func.is_list_type(item):
            if not all(isinstance(i, (str, int)) for i in item):
                raise Exception(
                    "List of columns to get item must be all of either string or int, cannot mix them"
                )

            if isinstance(item[0], int):
                return Table([self[i] for i in item], columns=self.columns)
            elif isinstance(item[0], str):
                return Table(
                    [func.take(d, *item) for d in self._data], columns=item)

    def __setitem__(self, key, value):
        if isinstance(key, str):
            for item in self._data:
                item[key] = value
            if not key in self.columns:
                self.columns.append(key)
        elif isinstance(key, int):
            self._data[key] = self._initialize_row(value)
        elif func.is_list_type(key):
            for k in key:
                self[k] = value

    def __delitem__(self, key):
        if isinstance(key, str):
            for item in self._data:
                del item[key]
            del self.columns[self.columns.index(key)]
        elif isinstance(key, int):
            del self._data[key]
        elif func.is_list_type(key):
            for k in key:
                del self[k]

    def __iter__(self):
        for d in self._data:
            yield copy.copy(d)

    def to_csv(self, f):
        is_path = False
        if isinstance(f, str):
            is_path = True
            f = open(f, mode='w')
        writer = csv.DictWriter(f, self.columns)
        writer.writerows(self._data)
        if is_path:
            f.close()

    def __repr__(self):
        return "Table [{headers}] (Rows: {num_rows})".format(
            headers=", ".join(self.columns), num_rows=len(self._data))

    def __str__(self):
        return json.dumps(self._data, indent=4, sort_keys=True)
