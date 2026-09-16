-- ============================================================================
-- Mini Encanto — RPC transaccional de venta (con descuento y recargo)
-- ----------------------------------------------------------------------------
-- Registra una venta completa en UNA transacción atómica (cabecera + stock +
-- movimientos + items + cuenta corriente). El total se calcula en el servidor:
--     total = subtotal - descuento + recargo
-- (el recargo sirve, por ejemplo, para el adicional por tarjeta de crédito).
--
-- Cómo aplicar: pegar COMPLETO en Supabase → SQL Editor → Run. Es idempotente.
-- ============================================================================

-- 0) Columna de recargo en ventas (si no existe)
alter table public.ventas add column if not exists recargo numeric default 0;

-- 1) Secuencia para el número de ticket, sembrada a un valor limpio.
create sequence if not exists public.ventas_num_seq;
select setval(
  'public.ventas_num_seq',
  greatest(1000, coalesce((select max(num) from public.ventas where num < 1000000000), 1000)),
  true
);

-- 2) Se elimina la versión anterior de la función (sin recargo) para reemplazar
--    su firma por la nueva.
drop function if exists public.registrar_venta(
  text, text, text, text, text, numeric, text, text, numeric, jsonb);

-- 3) Función transaccional de venta (con p_recargo).
create or replace function public.registrar_venta(
  p_cliente_id      text,
  p_cliente_nombre  text,
  p_cliente_tel     text,
  p_pago            text,
  p_tipo_precio     text,
  p_descuento       numeric,
  p_descuento_tipo  text,
  p_usuario         text,
  p_monto_cta       numeric,
  p_items           jsonb,
  p_recargo         numeric default 0
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_num       bigint;
  v_fecha     timestamptz := now();
  v_subtotal  numeric := 0;
  v_total     numeric;
  v_item      jsonb;
  v_var_id    text;
  v_qty       numeric;
  v_precio    numeric;
  v_stock     numeric;
  v_nuevo     numeric;
  v_saldo     numeric;
begin
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'La venta no tiene items';
  end if;

  v_num := nextval('public.ventas_num_seq');

  for v_item in select value from jsonb_array_elements(p_items) as t(value) loop
    v_subtotal := v_subtotal
      + (coalesce((v_item->>'precio')::numeric, 0)
       * coalesce((v_item->>'qty')::numeric, 0));
  end loop;
  v_total := v_subtotal - coalesce(p_descuento, 0) + coalesce(p_recargo, 0);

  insert into ventas (num, fecha, cliente, cliente_tel, pago, tipo_precio,
                      total, descuento, descuento_tipo, usuario, recargo)
  values (v_num, v_fecha, p_cliente_nombre, p_cliente_tel, p_pago, p_tipo_precio,
          v_total, coalesce(p_descuento, 0), p_descuento_tipo, p_usuario,
          coalesce(p_recargo, 0));

  for v_item in select value from jsonb_array_elements(p_items) as t(value) loop
    v_var_id := v_item->>'variante_id';
    v_qty    := coalesce((v_item->>'qty')::numeric, 0);
    v_precio := coalesce((v_item->>'precio')::numeric, 0);

    if v_var_id is not null and v_var_id <> '' then
      select stock into v_stock from variantes where id = v_var_id for update;
      if not found then
        raise exception 'Variante inexistente: %', v_var_id;
      end if;
      v_nuevo := greatest(0, coalesce(v_stock, 0) - v_qty);
      update variantes set stock = v_nuevo where id = v_var_id;

      insert into movimientos (tipo, producto, talle, qty, motivo, usuario, fecha)
      values ('venta', v_item->>'nombre', v_item->>'talle', v_qty,
              'Venta #' || v_num, p_usuario, v_fecha);
    end if;

    insert into items_ventas (venta_num, producto_id, nombre, talle, precio, qty)
    values (v_num, v_item->>'producto_id', v_item->>'nombre',
            v_item->>'talle', v_precio, v_qty);
  end loop;

  if p_cliente_id is not null and p_cliente_id <> '' and coalesce(p_monto_cta, 0) > 0 then
    select saldo into v_saldo from clientes where id = p_cliente_id for update;
    if found then
      update clientes set saldo = coalesce(v_saldo, 0) + p_monto_cta
      where id = p_cliente_id;
    end if;
  end if;

  return jsonb_build_object('num', v_num, 'fecha', v_fecha, 'total', v_total);
end;
$$;

revoke all on function public.registrar_venta(
  text, text, text, text, text, numeric, text, text, numeric, jsonb, numeric) from public;
grant execute on function public.registrar_venta(
  text, text, text, text, text, numeric, text, text, numeric, jsonb, numeric) to authenticated;
