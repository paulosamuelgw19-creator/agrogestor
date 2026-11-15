from threading import Lock
from time import monotonic

from fastapi import HTTPException


class LoginThrottle:
    def __init__(self, limit=8, window=300):
        self.limit = limit
        self.window = window
        self._attempts = {}
        self._lock = Lock()

    def reserve(self, identity):
        now = monotonic()
        with self._lock:
            self._attempts = {key: value for key, value in self._attempts.items() if value[0] > now - self.window}
            started, count = self._attempts.get(identity, (now, 0))
            if count >= self.limit:
                retry = max(1, int(started + self.window - now) + 1)
                raise HTTPException(status_code=429, detail="Muitas tentativas. Aguarde alguns minutos antes de tentar novamente.", headers={"Retry-After": str(retry)})
            if len(self._attempts) >= 4096 and identity not in self._attempts:
                # Fail closed instead of evicting counters that an attacker could reset.
                raise HTTPException(status_code=429, detail="Muitas tentativas. Aguarde alguns minutos.", headers={"Retry-After": str(self.window)})
            self._attempts[identity] = (started, count + 1)

    def clear(self, identity):
        with self._lock:
            self._attempts.pop(identity, None)
