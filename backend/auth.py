import time
import jwt
from config import SECRET_KEY

ALGORITHM = "HS256"


def create_token(account_number: str, server_broker: str, license_type: str) -> str:
    payload = {
        "account_number": account_number,
        "server_broker":  server_broker,
        "license_type":   license_type,
        "iat":            int(time.time()),
    }
    return jwt.encode(payload, SECRET_KEY, algorithm=ALGORITHM)


def decode_token(token: str) -> dict:
    return jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM],
                      options={"verify_iat": False})
