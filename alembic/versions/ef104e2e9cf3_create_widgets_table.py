"""create widgets table

Revision ID: ef104e2e9cf3
Revises: 
Create Date: 2026-09-10 22:44:21.457087

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'ef104e2e9cf3'
down_revision: Union[str, None] = None
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "widgets",
        sa.Column("id", sa.Integer, primary_key=True),
        sa.Column("name", sa.String(length=100), nullable=False),
    )


def downgrade() -> None:
    op.drop_table("widgets")
