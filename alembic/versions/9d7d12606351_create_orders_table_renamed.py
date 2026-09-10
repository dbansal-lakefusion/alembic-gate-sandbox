"""create orders table

Revision ID: 9d7d12606351
Revises: 8835ab9cf385
Create Date: 2026-09-10 22:44:21.720944

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '9d7d12606351'
down_revision: Union[str, None] = '8835ab9cf385'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "orders",
        sa.Column("id", sa.Integer, primary_key=True),
        sa.Column("widget_id", sa.Integer, sa.ForeignKey("widgets.id"), nullable=False),
    )


def downgrade() -> None:
    op.drop_table("orders")
