# Prenotazioni Centro Estetico (multi-operatore)

Progetto SEPARATO da quello di Ignazio: nuovo progetto Supabase, nuovo repository GitHub.

## File
- `schema_centro.sql` — database: operatori, trattamenti per operatore, orari per operatore, blocchi (singolo operatore o intero centro), festività, prenotazioni con anti-sovrapposizione PER OPERATORE, RLS, funzioni `get_occupazione` e `crea_prenotazione` (validazione lato server).
- `index.html` — pagina pubblica: scelta operatore → trattamenti (più d'uno, dello stesso operatore) → data → orario → dati.
- `admin.html` — agenda unica con filtro operatore, prenotazioni manuali/ricorrenti/modifica, trattamenti, operatori e orari, blocchi, statistiche.

## Setup
1. Crea un nuovo progetto Supabase. Esegui `schema_centro.sql` nel SQL Editor.
2. Authentication → Users: crea gli utenti admin; inserisci le loro email in `admin_emails` (a fondo schema c'è l'esempio).
3. In `index.html` e `admin.html` compila `CONFIG`/`NOME_CENTRO`, `SUPABASE_URL`, `SUPABASE_ANON_KEY` (la chiave anon/publishable, MAI la service_role).
4. Dall'area admin sostituisci i dati di esempio: operatori, trattamenti, orari. Aggiungi il santo patrono in `festivita_fisse`.
5. Pubblica su GitHub Pages.

## Note
- Pasqua e Pasquetta sono mobili: inseriscile ogni anno come blocco "Tutto il centro".
- Un blocco non annulla le prenotazioni già presenti (avvisa soltanto).
- Il pubblico non scrive mai direttamente sulle tabelle: passa solo da `crea_prenotazione`.
- I dati raccolti sono nome e telefono: serve un'informativa privacy (GDPR) e il form invita a non indicare dati sulla salute.
