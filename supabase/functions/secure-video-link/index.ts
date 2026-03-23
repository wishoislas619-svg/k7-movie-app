import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type' } })
  }

  try {
    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SB_ADMIN_KEY') ?? '' 
    )

    const url = new URL(req.url);
    if (url.pathname.includes('/admob-ssv')) {
      const ticket_id = url.searchParams.get('custom_data')?.trim(); 
      console.log(`[LOG] SSV PING RECIBIDO PARA TICKET: ${ticket_id}`);
      
      if (!ticket_id || ticket_id.length < 30) {
        return new Response('Test Request Verified', { status: 200 });
      }

      const { data, error } = await supabaseClient
        .from('ad_tickets')
        .update({ status: 'rewarded' })
        .eq('id', ticket_id)
        .select();

      if (error) {
        console.error('[DATABASE_ERROR]:', JSON.stringify(error));
        return new Response('Error Actualizando DB', { status: 500 });
      }
      
      if (!data || data.length === 0) {
        console.warn(`[NOT_FOUND]: El ticket ${ticket_id} no existe en la base de datos.`);
        return new Response('Ticket Not Found But Ping Received', { status: 200 }); // Retornamos 200 para que AdMob no reintente locamente, pero logueamos el error
      } else {
        console.log(`[SUCCESS]: Ticket ${ticket_id} marcado como REWARDED`);
        return new Response('Ad Verified', { status: 200 });
      }
    }

    const { media_id, media_type, ticket_id } = await req.json()
    
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) return new Response('Unauthorized', { status: 401 })

    const { data: { user } } = await supabaseClient.auth.getUser(authHeader.replace('Bearer ', ''))
    if (!user) return new Response('Token Inválido', { status: 401 })

    // Validar si el usuario es Admin o VIP para saltarse la publicidad por completo
    const userRole = user.user_metadata?.role?.toLowerCase();
    const isExempt = userRole === 'admin' || userRole === 'uservip';

    if (!isExempt) {
      if (!ticket_id) return new Response('Ticket requerido para usuarios standard', { status: 403 });

      const { data: ticket } = await supabaseClient
        .from('ad_tickets')
        .select('*')
        .eq('id', ticket_id)
        .eq('user_id', user.id)
        .eq('status', 'rewarded') 
        .single();

      if (!ticket) {
        return new Response(JSON.stringify({ error: 'Debes completar un anuncio para desbloquear el video.' }), { status: 403 })
      }

      await supabaseClient.from('ad_tickets').update({ status: 'consumed' }).eq('id', ticket.id);
    }

    let videoUrls = [];

    if (media_type === 'movie') {
      const { data: movie } = await supabaseClient.from('movies').select('urls').eq('id', media_id).single();
      videoUrls = JSON.parse(movie.urls || '[]');
    } else {
      const { data: episode } = await supabaseClient.from('episodes').select('urls').eq('id', media_id).single();
      videoUrls = JSON.parse(episode.urls || '[]');
    }

    const headers = { 'Access-Control-Allow-Origin': '*', 'Content-Type': 'application/json' };
    return new Response(JSON.stringify({ success: true, urls: videoUrls }), { headers, status: 200 })

  } catch (error: any) {
    return new Response(JSON.stringify({ error: error.message }), { headers: { 'Content-Type': 'application/json' }, status: 400 })
  }
})
