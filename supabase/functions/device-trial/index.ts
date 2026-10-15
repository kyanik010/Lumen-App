import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json; charset=utf-8",
};

function jsonResponse(status: number, payload: Record<string, unknown>) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: corsHeaders,
  });
}

Deno.serve(async (request: Request) => {
  if (request.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (request.method !== "POST") {
    return jsonResponse(405, { error: "method_not_allowed" });
  }

  let deviceId = "";
  try {
    const body = await request.json();
    deviceId = typeof body?.device_id === "string" ? body.device_id.trim() : "";
  } catch {
    return jsonResponse(400, { error: "invalid_json" });
  }

  // The client sends a one-way hash of Android's app-scoped device identifier.
  if (!/^EX-[A-F0-9]{64}$/.test(deviceId)) {
    return jsonResponse(400, { error: "invalid_device_id" });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) {
    return jsonResponse(500, { error: "server_configuration_error" });
  }

  const supabase = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // Insert only when this ID is first seen. An existing trial date is never reset.
  const { error: insertError } = await supabase
    .from("device_registry")
    .upsert(
      { device_id: deviceId },
      { onConflict: "device_id", ignoreDuplicates: true },
    );

  if (insertError) {
    console.error("device-trial insert failed", insertError.message);
    return jsonResponse(500, { error: "registration_failed" });
  }

  const now = new Date();
  const { data: device, error: readError } = await supabase
    .from("device_registry")
    .select(
      "device_id, first_seen_at, trial_expires_at, subscription_status, subscription_expires_at, device_status",
    )
    .eq("device_id", deviceId)
    .maybeSingle();

  if (readError || !device) {
    console.error("device-trial read failed", readError?.message ?? "not found");
    return jsonResponse(500, { error: "verification_failed" });
  }

  await supabase
    .from("device_registry")
    .update({ last_seen_at: now.toISOString() })
    .eq("device_id", deviceId);

  if (device.device_status === "blocked") {
    return jsonResponse(200, {
      allowed: false,
      status: "blocked",
      device_id: device.device_id,
      trial_expires_at: device.trial_expires_at,
    });
  }

  const subscriptionExpiry = device.subscription_expires_at
    ? new Date(device.subscription_expires_at)
    : null;
  const subscriptionActive =
    device.subscription_status === "active" &&
    (subscriptionExpiry === null || subscriptionExpiry.getTime() > now.getTime());

  if (subscriptionActive) {
    return jsonResponse(200, {
      allowed: true,
      status: "active",
      device_id: device.device_id,
      trial_expires_at: device.trial_expires_at,
      subscription_expires_at: device.subscription_expires_at,
    });
  }

  const trialExpiry = new Date(device.trial_expires_at);
  if (
    device.subscription_status === "trial" &&
    trialExpiry.getTime() > now.getTime()
  ) {
    return jsonResponse(200, {
      allowed: true,
      status: "trial",
      device_id: device.device_id,
      first_seen_at: device.first_seen_at,
      trial_expires_at: device.trial_expires_at,
    });
  }

  if (device.subscription_status === "trial") {
    await supabase
      .from("device_registry")
      .update({ subscription_status: "expired" })
      .eq("device_id", deviceId)
      .eq("subscription_status", "trial");
  }

  return jsonResponse(200, {
    allowed: false,
    status: "subscription_required",
    device_id: device.device_id,
    trial_expires_at: device.trial_expires_at,
    subscription_expires_at: device.subscription_expires_at,
  });
});
