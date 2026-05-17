import os
from dotenv import load_dotenv

load_dotenv()

SECRET_KEY   = os.getenv("SECRET_KEY",   "change-me-in-production")
DATABASE_URL = os.getenv("DATABASE_URL", "sqlite:///./ai_bridge.db")
HOST         = os.getenv("HOST",         "0.0.0.0")
PORT         = int(os.getenv("PORT",     "8000"))
