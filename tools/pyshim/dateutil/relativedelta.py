"""Minimal stand-in for `dateutil.relativedelta` (only what sqlglot's simplifier uses).

Used by tools/gen_optimizer_fixtures.py when python-dateutil isn't installed. It follows
dateutil's semantics for relative years/months/weeks/days/hours/minutes/seconds/microseconds.
"""

import calendar
import datetime


def _sign(x):
    return -1 if x < 0 else 1


class relativedelta:
    def __init__(
        self,
        years=0,
        months=0,
        days=0,
        weeks=0,
        hours=0,
        minutes=0,
        seconds=0,
        microseconds=0,
    ):
        self.years = years
        self.months = months
        self.days = days + weeks * 7
        self.hours = hours
        self.minutes = minutes
        self.seconds = seconds
        self.microseconds = microseconds
        self._fix()

    def _fix(self):
        if abs(self.microseconds) > 999999:
            s = _sign(self.microseconds)
            div, mod = divmod(self.microseconds * s, 1000000)
            self.microseconds = mod * s
            self.seconds += div * s
        if abs(self.seconds) > 59:
            s = _sign(self.seconds)
            div, mod = divmod(self.seconds * s, 60)
            self.seconds = mod * s
            self.minutes += div * s
        if abs(self.minutes) > 59:
            s = _sign(self.minutes)
            div, mod = divmod(self.minutes * s, 60)
            self.minutes = mod * s
            self.hours += div * s
        if abs(self.hours) > 23:
            s = _sign(self.hours)
            div, mod = divmod(self.hours * s, 24)
            self.hours = mod * s
            self.days += div * s
        if abs(self.months) > 11:
            s = _sign(self.months)
            div, mod = divmod(self.months * s, 12)
            self.months = mod * s
            self.years += div * s

    @property
    def _has_time(self):
        return bool(self.hours or self.minutes or self.seconds or self.microseconds)

    def __neg__(self):
        return relativedelta(
            years=-self.years,
            months=-self.months,
            days=-self.days,
            hours=-self.hours,
            minutes=-self.minutes,
            seconds=-self.seconds,
            microseconds=-self.microseconds,
        )

    def __add__(self, other):
        if not isinstance(other, datetime.date):
            return NotImplemented
        if self._has_time and not isinstance(other, datetime.datetime):
            other = datetime.datetime.fromordinal(other.toordinal())
        year = other.year + self.years
        month = other.month
        if self.months:
            month += self.months
            if month > 12:
                year += 1
                month -= 12
            elif month < 1:
                year -= 1
                month += 12
        day = min(calendar.monthrange(year, month)[1], other.day)
        ret = other.replace(year=year, month=month, day=day) + datetime.timedelta(
            days=self.days,
            hours=self.hours,
            minutes=self.minutes,
            seconds=self.seconds,
            microseconds=self.microseconds,
        )
        return ret

    __radd__ = __add__

    def __rsub__(self, other):
        return self.__neg__().__radd__(other)
