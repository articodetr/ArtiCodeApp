/*
  # Soft Void System for Movements

  ## Description
  Add soft-delete/void capability to account_movements to handle rejections and deletions
  without losing history. Voiding a movement removes it from balances but preserves the record.

  ## Changes
  1. Add soft-void fields to account_movements:
     - is_voided: boolean flag
     - voided_at: timestamp when voided
     - voided_by_user_id: who performed the void
     - void_type: 'rejected' or 'deleted'
     - void_reason: optional explanation

  2. These fields allow:
     - Reject movements created by linked accounts
     - Delete movements with full audit trail
     - Preserve history for notifications and reporting
*/

-- Add soft-void fields to account_movements
ALTER TABLE account_movements
ADD COLUMN IF NOT EXISTS is_voided boolean DEFAULT false NOT NULL,
ADD COLUMN IF NOT EXISTS voided_at timestamptz,
ADD COLUMN IF NOT EXISTS voided_by_user_id uuid REFERENCES app_security(id),
ADD COLUMN IF NOT EXISTS void_type text CHECK (void_type IN ('rejected', 'deleted')),
ADD COLUMN IF NOT EXISTS void_reason text;

-- Create index for filtering non-voided movements
CREATE INDEX IF NOT EXISTS idx_account_movements_not_voided 
ON account_movements(customer_id, created_at) 
WHERE is_voided = false;

-- Create index for voided movements
CREATE INDEX IF NOT EXISTS idx_account_movements_voided 
ON account_movements(voided_at) 
WHERE is_voided = true;

COMMENT ON COLUMN account_movements.is_voided IS 
  'Whether this movement has been voided (rejected or deleted)';

COMMENT ON COLUMN account_movements.void_type IS 
  'Type of void: rejected (by other party) or deleted (by creator)';

COMMENT ON COLUMN account_movements.void_reason IS 
  'Optional explanation for why the movement was voided';
