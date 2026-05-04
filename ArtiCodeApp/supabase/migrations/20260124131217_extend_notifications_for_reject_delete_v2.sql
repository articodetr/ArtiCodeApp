/*
  # Extend Notifications for Reject/Delete Flows

  ## Description
  Extend movement_notifications to support reject and delete notifications
  with snapshot data of movements (since they may be voided later).

  ## Changes
  1. Add snapshot fields to preserve movement details:
     - movement_number, amount, currency, movement_type
     - customer_name, actor_name (who created/rejected/deleted)
  
  2. Add new notification types:
     - movement_rejected: When other party rejects a movement
     - movement_deleted: When other party deletes a movement
  
  3. Enable realtime for instant notifications
*/

-- Add snapshot fields to movement_notifications
ALTER TABLE movement_notifications
ADD COLUMN IF NOT EXISTS movement_number text,
ADD COLUMN IF NOT EXISTS amount numeric(15,2),
ADD COLUMN IF NOT EXISTS currency text,
ADD COLUMN IF NOT EXISTS movement_type text,
ADD COLUMN IF NOT EXISTS customer_name text,
ADD COLUMN IF NOT EXISTS actor_name text,
ADD COLUMN IF NOT EXISTS extra_data jsonb DEFAULT '{}'::jsonb;

-- Update notification_type check constraint to include new types
DO $$ 
BEGIN
  -- Drop existing constraint if it exists
  ALTER TABLE movement_notifications 
  DROP CONSTRAINT IF EXISTS valid_notification_type;
  
  -- Add new constraint with all types (including existing ones)
  ALTER TABLE movement_notifications
  ADD CONSTRAINT valid_notification_type 
  CHECK (notification_type IN (
    'movement_added',
    'movement_approved', 
    'movement_rejected',
    'movement_deleted',
    'payment_reminder',
    'customer_added',
    'deletion_request'
  ));
END $$;

-- Create index for faster notification queries
CREATE INDEX IF NOT EXISTS idx_movement_notifications_user_created 
ON movement_notifications(user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_movement_notifications_unread 
ON movement_notifications(user_id, created_at DESC) 
WHERE is_read = false;

-- Enable realtime for instant notification delivery
DO $$
BEGIN
  -- Try to add the table to realtime publication
  -- This will fail silently if already added
  EXECUTE 'ALTER PUBLICATION supabase_realtime ADD TABLE movement_notifications';
EXCEPTION
  WHEN duplicate_object THEN NULL;
  WHEN others THEN NULL;
END $$;

COMMENT ON COLUMN movement_notifications.movement_number IS 
  'Snapshot of movement number at notification time';

COMMENT ON COLUMN movement_notifications.actor_name IS 
  'Name of user who performed the action (created/rejected/deleted)';

COMMENT ON COLUMN movement_notifications.extra_data IS 
  'Additional data like void_reason for rejected/deleted movements';
