import os
from sqlalchemy import create_engine, Column, String, Text, DateTime
from sqlalchemy.orm import declarative_base, sessionmaker
from datetime import datetime, timezone
from app.config import settings

if settings.DATABASE_URL.startswith("sqlite:///"):
    db_path = settings.DATABASE_URL.replace("sqlite:///", "")
    db_dir = os.path.dirname(db_path)
    if db_dir and not os.path.exists(db_dir):
        os.makedirs(db_dir, exist_ok=True)

engine = create_engine(
    settings.DATABASE_URL,
    connect_args={"check_same_thread": False} if "sqlite" in settings.DATABASE_URL else {}
)

SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base = declarative_base()

class UserProfileEntry(Base):
    __tablename__ = "user_profile"

    key = Column(String(120), primary_key=True, index=True)
    value = Column(Text, nullable=False)
    category = Column(String(60), default="general")
    updated_at = Column(DateTime, default=lambda: datetime.now(timezone.utc), onupdate=lambda: datetime.now(timezone.utc))

def init_db():
    Base.metadata.create_all(bind=engine)

def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
