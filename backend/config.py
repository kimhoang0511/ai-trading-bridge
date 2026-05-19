import os
from dotenv import load_dotenv

load_dotenv()

SECRET_KEY   = os.getenv("SECRET_KEY",   "change-me-in-production")
DATABASE_URL = os.getenv("DATABASE_URL", "sqlite:///./ai_bridge.db")
HOST         = os.getenv("HOST",         "0.0.0.0")
PORT         = int(os.getenv("PORT",     "8000"))

# Comma-separated account numbers that bypass license validation
WHITELISTED_ACCOUNTS: set[str] = {
    a.strip() for a in os.getenv("WHITELISTED_ACCOUNTS", "").split(",") if a.strip()
}
