-- Keep linked mirror movements in the same approval state.
-- هدف هذا التعديل:
-- 1) أي حركة بين أطراف مرتبطة تُسجل كمعلقة للطرفين.
-- 2) القبول أو الرفض من أحد الطرفين ينعكس مباشرة على الحركة المرآة.

create or replace function public.get_linked_mirror_pair_id(
  p_movement_id uuid,
  p_mirror_movement_id uuid default null
)
returns uuid
language plpgsql
as $$
declare
  v_pair_id uuid;
begin
  if p_mirror_movement_id is not null then
    return p_mirror_movement_id;
  end if;

  select am.id
    into v_pair_id
  from public.account_movements am
  where am.mirror_movement_id = p_movement_id
  limit 1;

  return v_pair_id;
end;
$$;

create or replace function public.linked_pair_requires_approval(
  p_customer_id uuid,
  p_pair_movement_id uuid
)
returns boolean
language plpgsql
as $$
declare
  v_pair_customer_id uuid;
  v_requires_approval boolean := false;
begin
  if p_customer_id is null or p_pair_movement_id is null then
    return false;
  end if;

  select customer_id
    into v_pair_customer_id
  from public.account_movements
  where id = p_pair_movement_id;

  if v_pair_customer_id is null then
    return false;
  end if;

  select exists (
    select 1
    from public.customers c
    where c.id in (p_customer_id, v_pair_customer_id)
      and c.linked_user_id is not null
  )
  into v_requires_approval;

  return coalesce(v_requires_approval, false);
end;
$$;

create or replace function public.sync_pending_state_for_linked_mirror_pair()
returns trigger
language plpgsql
as $$
declare
  v_pair_id uuid;
begin
  if pg_trigger_depth() > 1 then
    return null;
  end if;

  if coalesce(new.is_commission_movement, false) then
    return null;
  end if;

  v_pair_id := public.get_linked_mirror_pair_id(new.id, new.mirror_movement_id);

  if v_pair_id is null then
    return null;
  end if;

  if not public.linked_pair_requires_approval(new.customer_id, v_pair_id) then
    return null;
  end if;

  update public.account_movements
     set pending_approval = true,
         approval_status = 'pending',
         approved_by_user_id = null,
         approved_at = null,
         reject_reason = null
   where id in (new.id, v_pair_id)
     and coalesce(is_commission_movement, false) = false
     and coalesce(is_voided, false) = false
     and (
       pending_approval is distinct from true
       or approval_status is distinct from 'pending'
       or approved_by_user_id is not null
       or approved_at is not null
       or reject_reason is not null
     );

  return null;
end;
$$;

create or replace function public.sync_linked_mirror_pair_status()
returns trigger
language plpgsql
as $$
declare
  v_pair_id uuid;
  v_target_approved_at timestamptz;
  v_target_approved_by uuid;
  v_target_reject_reason text;
begin
  if pg_trigger_depth() > 1 then
    return null;
  end if;

  if coalesce(new.is_commission_movement, false) then
    return null;
  end if;

  v_pair_id := public.get_linked_mirror_pair_id(new.id, new.mirror_movement_id);

  if v_pair_id is null then
    return null;
  end if;

  if not public.linked_pair_requires_approval(new.customer_id, v_pair_id) then
    return null;
  end if;

  v_target_approved_at := case
    when new.approval_status = 'approved' then coalesce(new.approved_at, now())
    else null
  end;

  v_target_approved_by := case
    when new.approval_status = 'approved' then new.approved_by_user_id
    else null
  end;

  v_target_reject_reason := case
    when new.approval_status = 'rejected' then new.reject_reason
    else null
  end;

  update public.account_movements
     set pending_approval = new.pending_approval,
         approval_status = new.approval_status,
         approved_by_user_id = v_target_approved_by,
         approved_at = v_target_approved_at,
         reject_reason = v_target_reject_reason,
         is_voided = new.is_voided,
         void_type = new.void_type,
         void_reason = new.void_reason
   where id = v_pair_id
     and coalesce(is_commission_movement, false) = false
     and (
       pending_approval is distinct from new.pending_approval
       or approval_status is distinct from new.approval_status
       or approved_by_user_id is distinct from v_target_approved_by
       or approved_at is distinct from v_target_approved_at
       or reject_reason is distinct from v_target_reject_reason
       or is_voided is distinct from new.is_voided
       or void_type is distinct from new.void_type
       or void_reason is distinct from new.void_reason
     );

  return null;
end;
$$;

drop trigger if exists trg_sync_pending_state_for_linked_mirror_pair on public.account_movements;
create trigger trg_sync_pending_state_for_linked_mirror_pair
after insert or update of mirror_movement_id
on public.account_movements
for each row
execute function public.sync_pending_state_for_linked_mirror_pair();

drop trigger if exists trg_sync_linked_mirror_pair_status on public.account_movements;
create trigger trg_sync_linked_mirror_pair_status
after update of approval_status, pending_approval, approved_by_user_id, approved_at, reject_reason, is_voided, void_type, void_reason
on public.account_movements
for each row
execute function public.sync_linked_mirror_pair_status();
