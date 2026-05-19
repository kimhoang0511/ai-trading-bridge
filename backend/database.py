from sqlalchemy import create_engine, Column, Integer, Float, String, DateTime, UniqueConstraint
from sqlalchemy.orm import declarative_base, sessionmaker
from datetime import datetime, timezone
from config import DATABASE_URL as _RAW_DB_URL

# Normalize URL: Railway sometimes injects postgres:// or postgresql+asyncpg://
# Force psycopg2 (sync driver) for all PostgreSQL connections
DATABASE_URL = (
    _RAW_DB_URL
    .replace("postgresql+asyncpg://", "postgresql://")
    .replace("postgres://", "postgresql://")
)

_is_sqlite  = DATABASE_URL.startswith("sqlite")

_pool_kwargs: dict = {}
if _is_sqlite:
    # SQLite: single writer, use StaticPool for in-process concurrency safety
    from sqlalchemy.pool import StaticPool
    _pool_kwargs = {
        "connect_args": {"check_same_thread": False},
        "poolclass": StaticPool,
    }
else:
    # PostgreSQL / MySQL: tune pool for many concurrent users
    _pool_kwargs = {
        "pool_size":    10,   # persistent connections kept alive
        "max_overflow": 20,   # extra connections allowed under burst load
        "pool_timeout": 30,   # seconds to wait for a connection before raising
        "pool_recycle": 1800, # recycle connections every 30 min to avoid stale handles
        "pool_pre_ping": True, # validate connection before use
    }

engine = create_engine(DATABASE_URL, **_pool_kwargs)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base        = declarative_base()


class User(Base):
    __tablename__ = "users"

    id             = Column(Integer, primary_key=True, index=True)
    account_number = Column(String,  nullable=False)
    server_broker  = Column(String,  nullable=False)
    license_type   = Column(String,  nullable=False)   # DEMO | FULL | TIME
    active_date    = Column(DateTime, default=lambda: datetime.now(timezone.utc))
    token          = Column(String)
    created_at     = Column(DateTime, default=lambda: datetime.now(timezone.utc))
    updated_at     = Column(DateTime, default=lambda: datetime.now(timezone.utc))

    __table_args__ = (
        UniqueConstraint("account_number", "server_broker", name="uq_account_server"),
    )


class Strategy(Base):
    __tablename__ = "strategies"

    id             = Column(Integer, primary_key=True, index=True)
    account_number = Column(String,  nullable=False, index=True)
    sid            = Column(Integer, nullable=False)         # slot 0-4
    prompt         = Column(String,  nullable=False, default="")
    lot            = Column(Float,   nullable=False, default=0.1)
    sl             = Column(Integer, nullable=False, default=50)
    tp             = Column(Integer, nullable=False, default=100)
    tf             = Column(Integer, nullable=False, default=0)
    action         = Column(String,  nullable=False, default="BUY")
    symbol         = Column(String,  nullable=False, default="")
    updated_at     = Column(DateTime, default=lambda: datetime.now(timezone.utc))

    __table_args__ = (
        UniqueConstraint("account_number", "sid", name="uq_account_sid"),
    )


def init_db():
    Base.metadata.create_all(bind=engine)


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
