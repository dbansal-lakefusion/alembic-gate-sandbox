"""add widgets.sku column

Revision ID: 8835ab9cf385
Revises: ef104e2e9cf3
Create Date: 2026-09-10 22:44:21.590753

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '8835ab9cf385'
down_revision: Union[str, None] = 'ef104e2e9cf3'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("widgets", sa.Column("sku", sa.String(length=32), nullable=True))


def downgrade() -> None:
    op.drop_column("widgets", "sku")
