// src/lib/supabase.js
// ── Supabase client — used by all pages ──────────────────────
import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js/+esm'

const SUPABASE_URL = window._2LAK_CONFIG?.supabaseUrl || 'https://YOUR_PROJECT.supabase.co'
const SUPABASE_ANON = window._2LAK_CONFIG?.supabaseAnon || 'YOUR_ANON_KEY'

export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON)

// ── BRANCH ────────────────────────────────────────────────────
export async function getBranch(branchId) {
  const { data, error } = await supabase
    .from('branches')
    .select('*, providers(*)')
    .eq('id', branchId)
    .eq('is_active', true)
    .single()
  if (error) throw error
  return data
}

// ── PRIZES ────────────────────────────────────────────────────
export async function getPrizes(branchId) {
  const { data, error } = await supabase
    .from('prizes')
    .select('*')
    .eq('branch_id', branchId)
    .eq('is_active', true)
    .order('sort_order')
  if (error) throw error
  return data
}

// ── SESSION ───────────────────────────────────────────────────
export async function createSession(branchId, source, deviceFp) {
  const { data, error } = await supabase
    .from('sessions')
    .insert({ branch_id: branchId, source, device_fp: deviceFp })
    .select()
    .single()
  if (error) throw error
  return data
}

export async function checkOneTimeLock(branchId, phoneHash, deviceFp) {
  // Check phone hash
  if (phoneHash) {
    const { data } = await supabase
      .from('sessions')
      .select('id')
      .eq('branch_id', branchId)
      .eq('phone_hash', phoneHash)
      .not('coupon_code', 'is', null)
      .limit(1)
    if (data?.length) return { locked: true, reason: 'phone' }
  }
  // Check device fingerprint
  if (deviceFp) {
    const { data } = await supabase
      .from('sessions')
      .select('id')
      .eq('branch_id', branchId)
      .eq('device_fp', deviceFp)
      .not('coupon_code', 'is', null)
      .limit(1)
    if (data?.length) return { locked: true, reason: 'device' }
  }
  return { locked: false }
}

export async function updateSessionSpin(sessionId, prizeId, prizeLabel) {
  const { data, error } = await supabase
    .from('sessions')
    .update({ prize_id: prizeId, spin_result: prizeLabel, spun_at: new Date().toISOString() })
    .eq('id', sessionId)
    .select().single()
  if (error) throw error
  return data
}

export async function updateSessionRating(sessionId, rating) {
  const { data, error } = await supabase
    .from('sessions')
    .update({ rating, rated_at: new Date().toISOString() })
    .eq('id', sessionId)
    .select().single()
  if (error) throw error
  return data
}

export async function updateSessionOTP(sessionId, phone, phoneHash) {
  const { error } = await supabase
    .from('sessions')
    .update({ phone, phone_hash: phoneHash, otp_verified: true, otp_verified_at: new Date().toISOString() })
    .eq('id', sessionId)
  if (error) throw error
}

export async function issueCoupon(sessionId, branchId, prizeId) {
  // Call Supabase Edge Function to generate coupon server-side
  const { data, error } = await supabase.functions.invoke('issue-coupon', {
    body: { session_id: sessionId, branch_id: branchId, prize_id: prizeId }
  })
  if (error) throw error
  return data // { coupon_code, expires_at }
}

export async function trackReviewClick(sessionId, platform) {
  await supabase
    .from('sessions')
    .update({ review_clicked: true, review_platform: platform, review_clicked_at: new Date().toISOString() })
    .eq('id', sessionId)
}

export async function revealQRInDB(sessionId) {
  await supabase
    .from('sessions')
    .update({ qr_revealed: true, qr_revealed_at: new Date().toISOString() })
    .eq('id', sessionId)
}

export async function submitComplaint(sessionId, branchId, chips, text) {
  await supabase.from('complaints').insert({
    session_id: sessionId, branch_id: branchId, chips, text
  })
  await supabase
    .from('sessions')
    .update({ complaint_chips: chips, complaint_text: text, complaint_submitted_at: new Date().toISOString() })
    .eq('id', sessionId)
}

// ── REDEEM (Staff) ────────────────────────────────────────────
export async function getSessionByCoupon(couponCode) {
  const { data, error } = await supabase
    .from('sessions')
    .select('*, branches(name, providers(name))')
    .eq('coupon_code', couponCode)
    .single()
  if (error) throw error
  return data
}

export async function redeemCoupon(sessionId, staffName) {
  const { error } = await supabase
    .from('sessions')
    .update({ redeemed: true, redeemed_at: new Date().toISOString(), redeemed_by: staffName })
    .eq('id', sessionId)
    .eq('redeemed', false) // prevent double redeem
  if (error) throw error
}

export async function cancelRedeem(sessionId) {
  await supabase
    .from('sessions')
    .update({ redeem_cancelled: true })
    .eq('id', sessionId)
}
