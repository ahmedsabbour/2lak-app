// supabase/functions/issue-coupon/index.ts
// Server-side coupon generation — prevents client-side tampering
import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

serve(async (req) => {
  const { session_id, branch_id, prize_id } = await req.json()

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
  )

  // Verify session exists and not already issued
  const { data: session } = await supabase
    .from('sessions')
    .select('coupon_code, prize_id')
    .eq('id', session_id)
    .single()

  if (session?.coupon_code) {
    return new Response(JSON.stringify({ coupon_code: session.coupon_code }), { status: 200 })
  }

  // Get prize details
  const { data: prize } = await supabase
    .from('prizes')
    .select('coupon_prefix, valid_days, is_win')
    .eq('id', prize_id)
    .single()

  if (!prize?.is_win) {
    return new Response(JSON.stringify({ coupon_code: null }), { status: 200 })
  }

  // Generate unique code server-side
  const { data: code } = await supabase.rpc('generate_coupon_code', {
    prefix: prize.coupon_prefix || 'PRIZE'
  })

  const expiresAt = new Date()
  expiresAt.setDate(expiresAt.getDate() + (prize.valid_days || 7))

  await supabase
    .from('sessions')
    .update({
      coupon_code: code,
      coupon_issued_at: new Date().toISOString(),
      coupon_expires_at: expiresAt.toISOString(),
    })
    .eq('id', session_id)

  return new Response(
    JSON.stringify({ coupon_code: code, expires_at: expiresAt.toISOString() }),
    { headers: { 'Content-Type': 'application/json' } }
  )
})
