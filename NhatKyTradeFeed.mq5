//+------------------------------------------------------------------+
//| NhatKyTradeFeed.mq5                                               |
//| WHAT IT SENDS to Nhật Ký Trade: quotes and candles; the account's     |
//| balance, equity, currency, number and server name; its open       |
//| positions and pending orders; closed trades only while            |
//| auto-journal is on. It reads no password, and imports no DLL.     |
//| Takes orders from the web ONLY when AllowTrading is true in the   |
//| Inputs (default false), never above MaxLot, never without a stop  |
//| loss. It only opens orders: it never modifies or closes one.      |
//+------------------------------------------------------------------+
#property copyright "Nhật Ký Trade"
#property link      "https://nhatkytrade.com"
#property version   "1.16"
#property description "Sends prices, candles, the account's balance, equity and number, and its open orders to Nhật Ký Trade."
#property description "Places orders from the web only with AllowTrading = true. Never modifies or closes one."

input string Token        = "";                                                  // Token (Cài đặt → Kết nối MT4/MT5)
input string Symbols      = "XAUUSD,EURUSD,GBPUSD,USDJPY,AUDUSD,USDCAD,USDCHF,NZDUSD"; // Symbols
input bool   AllowTrading = false;                                               // AllowTrading (nhận lệnh từ web)
input double MaxLot       = 0.10;                                                // MaxLot (lot tối đa mỗi lệnh)
input int    Slippage     = 20;                                                  // Slippage (points, lệnh thị trường)
input long   Magic        = 20261110;                                            // Magic
input string Lang         = "vi";                                                // vi | en
input string FeedUrl      = "https://nhatkytrade.com/api/mt5/feed";                                        // Feed URL

#define MAX_SYMBOLS 20
#define FULL_BARS   300
#define HIST_MAX_BARS 20000  // one series for the backtest page, at most
#define TF_COUNT    4
#define ORDER_MAX_AGE_MS 30000
#define MAX_RESULTS 20

ENUM_TIMEFRAMES g_tfs[TF_COUNT]     = {PERIOD_M15, PERIOD_H1, PERIOD_H4, PERIOD_D1};
string          g_tfNames[TF_COUNT] = {"M15", "H1", "H4", "D1"};

string g_base[];       // app names: XAUUSD
string g_broker[];     // this broker's names: XAUUSDm ("" when not offered)
string g_need  = "*";  // series to resend in full; "*" = all of them
string g_jsince = "";  // auto-journal: broker time to read closed deals from; "" = off
int    g_round = 0;
int    g_tick  = 0;
bool   g_stopped = false;
string g_line  = "";   // what the last feed push said
string g_tradeLine = "";
string g_results = ""; // order results not yet accepted by the server, JSON objects
int    g_resultCount = 0;

string Msg(string vi, string en)
  {
   if(Lang == "en")
      return en;
   return vi;
  }

// Upper-case letters and digits only: "XAUUSDm" -> "XAUUSDM", "#EURUSD.raw" -> "EURUSDRAW".
string Clean(string s)
  {
   StringToUpper(s);
   string out = "";
   int n = StringLen(s);
   for(int i = 0; i < n; i++)
     {
      ushort ch = StringGetCharacter(s, i);
      if((ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9'))
         out += ShortToString(ch);
     }
   return out;
  }

string FindIn(bool selectedOnly, string base, string alias)
  {
   string fallback = "";
   int total = SymbolsTotal(selectedOnly);
   for(int i = 0; i < total; i++)
     {
      string name = SymbolName(i, selectedOnly);
      string c = Clean(name);
      if(c == base)
         return name;
      if(fallback == "" && StringFind(c, base) == 0)
         fallback = name;
      if(fallback == "" && alias != "" && StringFind(c, alias) == 0)
         fallback = name;
     }
   return fallback;
  }

// The broker's own name for an app symbol, preferring what is already in Market Watch.
string ResolveSymbol(string base)
  {
   string alias = "";
   if(base == "XAUUSD")
      alias = "GOLD";
   if(base == "XAGUSD")
      alias = "SILVER";
   string name = FindIn(true, base, alias);
   if(name == "")
      name = FindIn(false, base, alias);
   if(name != "")
      SymbolSelect(name, true);
   return name;
  }

void AddSymbol(string base)
  {
   base = Clean(base);
   if(StringLen(base) < 4)
      return;
   int n = ArraySize(g_base);
   for(int i = 0; i < n; i++)
      if(g_base[i] == base)
         return;
   if(n >= MAX_SYMBOLS)
      return;
   ArrayResize(g_base, n + 1);
   ArrayResize(g_broker, n + 1);
   g_base[n] = base;
   g_broker[n] = ResolveSymbol(base);
  }

string JsonText(string s)
  {
   StringReplace(s, "\\", "\\\\");
   StringReplace(s, "\"", "\\\"");
   StringReplace(s, "\r", " ");
   StringReplace(s, "\n", " ");
   StringReplace(s, "\t", " ");
   return s;
  }

// Value of "key":"..." in the server's flat JSON answer.
string JsonField(string json, string key)
  {
   string pattern = "\"" + key + "\":\"";
   int start = StringFind(json, pattern);
   if(start < 0)
      return "";
   start += StringLen(pattern);
   int end = StringFind(json, "\"", start);
   if(end < 0)
      return "";
   return StringSubstr(json, start, end - start);
  }

string Host()
  {
   int start = StringFind(FeedUrl, "://");
   if(start < 0)
      return FeedUrl;
   int end = StringFind(FeedUrl, "/", start + 3);
   if(end < 0)
      return FeedUrl;
   return StringSubstr(FeedUrl, 0, end);
  }

// Same host as the feed, so the one WebRequest permission covers both.
string OrdersUrl()
  {
   string url = FeedUrl;
   StringReplace(url, "/api/mt5/feed", "/api/mt5/orders/poll");
   return url;
  }

string HistoryUrl()
  {
   string url = FeedUrl;
   StringReplace(url, "/api/mt5/feed", "/api/mt5/history");
   return url;
  }

// Long history for the backtest page (EA 1.14). The feed answer names one
// series in "hist" - "XAUUSDm|H1|10000" - and this sends it to its own URL,
// so a 20 000-bar upload never delays the prices.
//
// NOT ON THE FIRST COPY (EA 1.16). For a pair with no chart open, MetaTrader
// holds only the bars it built from ticks since it started - 17 H1 gold bars
// on the owner's MT4, 11/11/2026 - and CopyRates answers with those while the
// rest is still on its way from the broker. 1.15 sent that answer at once, and
// the page showed 16 bars for 10 000. Now the request is kept and copied again
// every push (~5 s) until MetaTrader is done: all that was asked is there, or
// the count stood still for HIST_STABLE_ROUNDS pushes with nothing loading,
// or HIST_MAX_TRIES pushes (about a minute) have gone by.
#define HIST_STABLE_ROUNDS 2
#define HIST_MAX_TRIES     12
string g_histReq   = "";  // the series waiting: "XAUUSDm|H1|10000"
int    g_histTries = 0;
int    g_histLast  = -1;  // bars the last push copied
int    g_histSame  = 0;   // pushes in a row with no new bars

void QueueHistory(string req)
  {
   // The server hands an unanswered request out again after 45 s: same one, keep waiting.
   if(req == g_histReq)
      return;
   g_histReq = req;
   g_histTries = 0;
   g_histLast = -1;
   g_histSame = 0;
  }

void StepHistory()
  {
   if(g_histReq == "")
      return;
   string parts[];
   int k = -1;
   int count = 0;
   if(StringSplit(g_histReq, '|', parts) == 3)
     {
      for(int i = 0; i < TF_COUNT; i++)
         if(g_tfNames[i] == parts[1])
            k = i;
      count = (int)StringToInteger(parts[2]);
     }
   if(k < 0 || count <= 0)
     {
      g_histReq = "";
      return;
     }
   if(count > HIST_MAX_BARS)
      count = HIST_MAX_BARS;
   string sym = parts[0];
   MqlRates rates[];
   ResetLastError();
   int got = CopyRates(sym, g_tfs[k], 0, count, rates);
   bool loading = !(bool)SeriesInfoInteger(sym, g_tfs[k], SERIES_SYNCHRONIZED);
   g_histTries++;
   if(got > 0 && got == g_histLast && !loading)
      g_histSame++;
   else
      g_histSame = 0;
   g_histLast = got;
   if(got < count && g_histSame < HIST_STABLE_ROUNDS && g_histTries < HIST_MAX_TRIES)
     {
      string n = IntegerToString(got > 0 ? got : 0);
      Show(Msg("đang chờ MT5 tải lịch sử " + sym + " " + parts[1] + " · " + n + " nến",
               "waiting for MT5 to load " + sym + " " + parts[1] + " history · " + n + " bars"));
      return;
     }
   g_histReq = "";
   if(got > 0)
      SendRates(sym, parts[1], count, rates, got);
  }

void SendRates(string sym, string tfName, int count, MqlRates &rates[], int got)
  {
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   // In chunks: += on one growing string copies all of it every time, and
   // 20 000 rows that way would copy gigabytes.
   string rows = "";
   string chunk = "";
   for(int j = 0; j < got; j++)
     {
      if(j > 0)
         chunk += ",";
      chunk += "[" + IntegerToString((long)rates[j].time)
               + "," + DoubleToString(rates[j].open, digits)
               + "," + DoubleToString(rates[j].high, digits)
               + "," + DoubleToString(rates[j].low, digits)
               + "," + DoubleToString(rates[j].close, digits)
               + "," + IntegerToString((long)rates[j].tick_volume) + "]";
      if(j % 500 == 499)
        {
         StringAdd(rows, chunk);
         chunk = "";
        }
     }
   StringAdd(rows, chunk);
   string body = "{\"v\":1,\"offset\":" + IntegerToString((long)(TimeTradeServer() - TimeGMT()))
                 + ",\"s\":\"" + sym + "\",\"tf\":\"" + tfName
                 + "\",\"d\":" + IntegerToString(digits)
                 + ",\"r\":[" + rows + "]}";
   string response;
   int status = Post(HistoryUrl(), body, 30000, response);
   if(status != 200)
      Failed(status);
   else if(got < count)
      // All the broker gave without a chart: one open and scrolled back holds more.
      Show(Msg("đã gửi lịch sử " + sym + " " + tfName + " · " + IntegerToString(got) + " nến - MT5 chỉ có chừng này. Muốn thêm: mở biểu đồ " + sym + " " + tfName + ", bấm Home vài lần, rồi Tải lại trên web",
               "history sent " + sym + " " + tfName + " · " + IntegerToString(got) + " bars - all MT5 has. For more: open a " + sym + " " + tfName + " chart, press Home a few times, then Reload on the web"));
   else
      Show(Msg("đã gửi lịch sử " + sym + " " + tfName + " · " + IntegerToString(got) + " nến",
               "history sent " + sym + " " + tfName + " · " + IntegerToString(got) + " bars"));
  }

string Missing()
  {
   string out = "";
   for(int i = 0; i < ArraySize(g_base); i++)
      if(g_broker[i] == "")
         out += (out == "" ? "" : ", ") + g_base[i];
   return out;
  }

void Render()
  {
   string text = "Nhật Ký Trade · " + g_line;
   if(g_tradeLine != "")
      text += "\n" + g_tradeLine;
   string missing = Missing();
   if(missing != "")
      text += "\n" + Msg("Sàn này không có: ", "Not offered by this broker: ") + missing;
   Comment(text);
  }

void Show(string line)
  {
   g_line = line;
   Render();
  }

// Sends a JSON body; returns the HTTP status (-1 = not sent) and the answer.
int Post(string url, string body, int timeoutMs, string &response)
  {
   char data[];
   int len = StringToCharArray(body, data, 0, WHOLE_ARRAY, CP_UTF8);
   if(len > 0)
      ArrayResize(data, len - 1);  // drop the terminating zero
   char result[];
   string resultHeaders;
   string headers = "Content-Type: application/json\r\nAuthorization: Bearer " + Token + "\r\n";
   ResetLastError();
   int status = WebRequest("POST", url, headers, timeoutMs, data, result, resultHeaders);
   response = "";
   if(status != -1)
      response = CharArrayToString(result, 0, WHOLE_ARRAY, CP_UTF8);
   return status;
  }

// A request that failed, said on the chart. Returns true when the EA must stop.
bool Failed(int status)
  {
   if(status == -1)
     {
      int err = GetLastError();
      if(err == 4014)
         Show(Msg("MT5 chưa cho phép gửi tới " + Host() + ". Vào Tools → Options → Expert Advisors, bật \"Allow WebRequest for listed URL\" và thêm " + Host() + ".",
                  "MT5 does not allow requests to " + Host() + " yet. Go to Tools → Options → Expert Advisors, tick \"Allow WebRequest for listed URL\" and add " + Host() + "."));
      else
         Show(Msg("Không gửi được (lỗi " + IntegerToString(err) + "). EA sẽ thử lại.",
                  "Could not send (error " + IntegerToString(err) + "). The EA will retry."));
      return false;
     }
   if(status == 401)
     {
      g_stopped = true;
      EventKillTimer();
      Show(Msg("Mã kết nối sai hoặc đã bị thu hồi. Tạo mã mới ở Cài đặt → Kết nối MT4/MT5 rồi gắn lại EA.",
               "The connection token is wrong or was revoked. Create a new one in Settings → MT4/MT5 connection and attach the EA again."));
      return true;
     }
   Show(Msg("Máy chủ trả mã " + IntegerToString(status) + ". EA sẽ thử lại.",
            "The server answered " + IntegerToString(status) + ". The EA will retry."));
   return false;
  }

// Every open position, as the journal wants it.
string OpenPositions()
  {
   string out = "";
   int total = PositionsTotal();
   for(int i = 0; i < total && i < 200; i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      string psym = PositionGetString(POSITION_SYMBOL);
      int pd = (int)SymbolInfoInteger(psym, SYMBOL_DIGITS);
      if(out != "")
         out += ",";
      out += "{\"id\":" + IntegerToString(PositionGetInteger(POSITION_IDENTIFIER))
             + ",\"s\":\"" + JsonText(psym) + "\""
             + ",\"t\":" + (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? "0" : "1")
             + ",\"v\":" + DoubleToString(PositionGetDouble(POSITION_VOLUME), 2)
             + ",\"p\":" + DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN), pd)
             + ",\"o\":" + IntegerToString(PositionGetInteger(POSITION_TIME))
             + ",\"sl\":" + DoubleToString(PositionGetDouble(POSITION_SL), pd)
             + ",\"tp\":" + DoubleToString(PositionGetDouble(POSITION_TP), pd) + "}";
     }
   return out;
  }

bool IsOpenPosition(long pid)
  {
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
     {
      if(PositionGetTicket(i) == 0)
         continue;
      if(PositionGetInteger(POSITION_IDENTIFIER) == pid)
         return true;
     }
   return false;
  }

// Every open position and pending order, all symbols, for the chart page to
// draw (payload "work"). ENUM_ORDER_TYPE numbers are the wire's type numbers.
string WorkingOrders()
  {
   string out = "";
   int np = PositionsTotal();
   for(int i = 0; i < np && i < 200; i++)
     {
      if(PositionGetTicket(i) == 0)
         continue;
      string ws = PositionGetString(POSITION_SYMBOL);
      int wd = (int)SymbolInfoInteger(ws, SYMBOL_DIGITS);
      if(out != "")
         out += ",";
      out += "{\"id\":" + IntegerToString(PositionGetInteger(POSITION_IDENTIFIER))
             + ",\"s\":\"" + JsonText(ws) + "\""
             + ",\"t\":" + (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? "0" : "1")
             + ",\"v\":" + DoubleToString(PositionGetDouble(POSITION_VOLUME), 2)
             + ",\"p\":" + DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN), wd)
             + ",\"sl\":" + DoubleToString(PositionGetDouble(POSITION_SL), wd)
             + ",\"tp\":" + DoubleToString(PositionGetDouble(POSITION_TP), wd) + "}";
     }
   int no = OrdersTotal();
   for(int i = 0; i < no && i < 200; i++)
     {
      ulong ot = OrderGetTicket(i);
      if(ot == 0)
         continue;
      long type = OrderGetInteger(ORDER_TYPE);
      // Market orders in flight are positions a moment later; only pending ones here.
      if(type < ORDER_TYPE_BUY_LIMIT || type > ORDER_TYPE_SELL_STOP_LIMIT)
         continue;
      string ws = OrderGetString(ORDER_SYMBOL);
      int wd = (int)SymbolInfoInteger(ws, SYMBOL_DIGITS);
      if(out != "")
         out += ",";
      out += "{\"id\":" + IntegerToString((long)ot)
             + ",\"s\":\"" + JsonText(ws) + "\""
             + ",\"t\":" + IntegerToString(type)
             + ",\"v\":" + DoubleToString(OrderGetDouble(ORDER_VOLUME_CURRENT), 2)
             + ",\"p\":" + DoubleToString(OrderGetDouble(ORDER_PRICE_OPEN), wd)
             + ",\"sl\":" + DoubleToString(OrderGetDouble(ORDER_SL), wd)
             + ",\"tp\":" + DoubleToString(OrderGetDouble(ORDER_TP), wd) + "}";
     }
   return out;
  }

// One summary per position fully closed since the given broker time.
string ClosedPositions(datetime since)
  {
   long pids[];
   int np = 0;
   if(!HistorySelect(since, TimeCurrent() + 3600))
      return "";
   int deals = HistoryDealsTotal();
   for(int i = 0; i < deals; i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0)
         continue;
      long entry = HistoryDealGetInteger(d, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY && entry != DEAL_ENTRY_INOUT)
         continue;
      long pid = HistoryDealGetInteger(d, DEAL_POSITION_ID);
      if(pid <= 0)
         continue;
      bool seen = false;
      for(int k = 0; k < np; k++)
         if(pids[k] == pid)
            seen = true;
      if(seen || np >= 50)
         continue;
      ArrayResize(pids, np + 1);
      pids[np] = pid;
      np++;
     }

   string out = "";
   for(int k = 0; k < np; k++)
     {
      // Partly closed and still open: the journal waits for the end.
      if(IsOpenPosition(pids[k]))
         continue;
      if(!HistorySelectByPosition(pids[k]))
         continue;
      double vin = 0, pin = 0, vout = 0, pout = 0, pr = 0, sw = 0, cm = 0, fee = 0, sl = 0, tp = 0;
      long tin = 0, tout = 0, dtype = -1;
      string dsym = "";
      int n = HistoryDealsTotal();
      for(int j = 0; j < n; j++)
        {
         ulong d = HistoryDealGetTicket(j);
         if(d == 0)
            continue;
         long e = HistoryDealGetInteger(d, DEAL_ENTRY);
         double v = HistoryDealGetDouble(d, DEAL_VOLUME);
         double p = HistoryDealGetDouble(d, DEAL_PRICE);
         long tm = HistoryDealGetInteger(d, DEAL_TIME);
         pr  += HistoryDealGetDouble(d, DEAL_PROFIT);
         sw  += HistoryDealGetDouble(d, DEAL_SWAP);
         cm  += HistoryDealGetDouble(d, DEAL_COMMISSION);
         fee += HistoryDealGetDouble(d, DEAL_FEE);
         if(e == DEAL_ENTRY_IN)
           {
            if(tin == 0)
              {
               tin = tm;
               dtype = HistoryDealGetInteger(d, DEAL_TYPE);
               dsym = HistoryDealGetString(d, DEAL_SYMBOL);
               sl = HistoryDealGetDouble(d, DEAL_SL);
               tp = HistoryDealGetDouble(d, DEAL_TP);
              }
            vin += v;
            pin += v * p;
           }
         else
           {
            vout += v;
            pout += v * p;
            if(tm > tout)
               tout = tm;
           }
        }
      // The entry happened before history could be read: no honest row.
      if(vin <= 0 || vout <= 0 || tin == 0 || dsym == "")
         continue;
      int pd = (int)SymbolInfoInteger(dsym, SYMBOL_DIGITS);
      if(out != "")
         out += ",";
      out += "{\"id\":" + IntegerToString(pids[k])
             + ",\"s\":\"" + JsonText(dsym) + "\""
             + ",\"t\":" + (dtype == DEAL_TYPE_BUY ? "0" : "1")
             + ",\"v\":" + DoubleToString(vin, 2)
             + ",\"p\":" + DoubleToString(pin / vin, pd + 2)
             + ",\"o\":" + IntegerToString(tin)
             + ",\"x\":" + DoubleToString(pout / vout, pd + 2)
             + ",\"c\":" + IntegerToString(tout)
             + ",\"pr\":" + DoubleToString(pr, 2)
             + ",\"sw\":" + DoubleToString(sw, 2)
             + ",\"cm\":" + DoubleToString(cm, 2)
             + ",\"fee\":" + DoubleToString(fee, 2)
             + ",\"sl\":" + DoubleToString(sl, pd)
             + ",\"tp\":" + DoubleToString(tp, pd) + "}";
     }
   return out;
  }

void Push()
  {
   bool fullAll = (g_need == "*");
   bool withBars = fullAll || g_need != "" || (g_round % 3 == 0);
   g_round++;

   string quotes = "";
   string bars = "";
   string specs = "";
   int sent = 0;
   for(int i = 0; i < ArraySize(g_broker); i++)
     {
      string sym = g_broker[i];
      if(sym == "")
         continue;
      int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      MqlTick tick;
      if(SymbolInfoTick(sym, tick) && tick.bid > 0 && tick.ask > 0)
        {
         if(quotes != "")
            quotes += ",";
         quotes += "{\"s\":\"" + sym + "\",\"b\":" + DoubleToString(tick.bid, digits)
                   + ",\"a\":" + DoubleToString(tick.ask, digits)
                   + ",\"d\":" + IntegerToString(digits) + "}";
         sent++;
        }
      if(!withBars)
         continue;
      // The broker's own contract terms; tick values are in the account's currency.
      if(specs != "")
         specs += ",";
      specs += "{\"s\":\"" + sym + "\""
               + ",\"ts\":" + DoubleToString(SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE), 8)
               + ",\"tvl\":" + DoubleToString(SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE_LOSS), 8)
               + ",\"tvp\":" + DoubleToString(SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE_PROFIT), 8)
               + ",\"cs\":" + DoubleToString(SymbolInfoDouble(sym, SYMBOL_TRADE_CONTRACT_SIZE), 4)
               + ",\"vmin\":" + DoubleToString(SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN), 4)
               + ",\"vstep\":" + DoubleToString(SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP), 4)
               + ",\"vmax\":" + DoubleToString(SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX), 4) + "}";
      for(int k = 0; k < TF_COUNT; k++)
        {
         bool full = fullAll || StringFind(g_need, sym + "|" + g_tfNames[k] + ";") >= 0;
         MqlRates rates[];
         int got = CopyRates(sym, g_tfs[k], 0, full ? FULL_BARS : 2, rates);
         if(got <= 0)
            continue;
         string rows = "";
         for(int j = 0; j < got; j++)
           {
            if(j > 0)
               rows += ",";
            rows += "[" + IntegerToString((long)rates[j].time)
                    + "," + DoubleToString(rates[j].open, digits)
                    + "," + DoubleToString(rates[j].high, digits)
                    + "," + DoubleToString(rates[j].low, digits)
                    + "," + DoubleToString(rates[j].close, digits)
                    + "," + IntegerToString((long)rates[j].tick_volume) + "]";
           }
         if(bars != "")
            bars += ",";
         bars += "{\"s\":\"" + sym + "\",\"tf\":\"" + g_tfNames[k]
                 + "\",\"d\":" + IntegerToString(digits)
                 + ",\"full\":" + (full ? "true" : "false")
                 + ",\"r\":[" + rows + "]}";
        }
     }

   // Auto-journal, on the candle rounds and only while the reader has it on.
   string journal = "";
   if(withBars && g_jsince != "")
      journal = ",\"open\":[" + OpenPositions() + "]"
                + ",\"closed\":[" + ClosedPositions((datetime)StringToInteger(g_jsince)) + "]";

   // What is working now, on the same rounds, auto-journal or not.
   string work = "";
   if(withBars)
      work = ",\"work\":[" + WorkingOrders() + "]";

   long offset = (long)(TimeTradeServer() - TimeGMT());
   string body = "{\"v\":1,\"server\":\"" + JsonText(AccountInfoString(ACCOUNT_SERVER))
                 + "\",\"login\":" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN))
                 + ",\"offset\":" + IntegerToString(offset)
                 + ",\"ccy\":\"" + JsonText(AccountInfoString(ACCOUNT_CURRENCY)) + "\""
                 + ",\"bal\":" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2)
                 + ",\"eq\":" + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2)
                 + ",\"specs\":[" + specs + "]"
                 + journal
                 + work
                 + ",\"quotes\":[" + quotes + "],\"bars\":[" + bars + "]}";

   string response;
   int status = Post(FeedUrl, body, 15000, response);
   if(status != 200)
     {
      Failed(status);
      return;
     }
   g_need = JsonField(response, "need");
   g_jsince = JsonField(response, "jsince");
   string want = JsonField(response, "want");
   if(want != "")
     {
      string parts[];
      int n = StringSplit(want, ',', parts);
      for(int i = 0; i < n; i++)
         AddSymbol(parts[i]);
     }
   Show(Msg("đã gửi " + TimeToString(TimeLocal(), TIME_SECONDS) + " · " + IntegerToString(sent) + " mã",
            "sent " + TimeToString(TimeLocal(), TIME_SECONDS) + " · " + IntegerToString(sent) + " symbols"));
   string hist = JsonField(response, "hist");
   if(hist != "")
      QueueHistory(hist);
   StepHistory();
  }

//+------------------------------------------------------------------+
//| Orders from the web — only with AllowTrading = true              |
//+------------------------------------------------------------------+

// Every switch between this EA and the broker: the EA's own input, MT5's
// Algo Trading button, the EA's "Allow Algo Trading" box, and the account
// (an investor-password login cannot trade).
bool CanTrade()
  {
   return AllowTrading
          && TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) != 0
          && MQLInfoInteger(MQL_TRADE_ALLOWED) != 0
          && AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) != 0
          && AccountInfoInteger(ACCOUNT_TRADE_EXPERT) != 0;
  }

double LotCap()
  {
   return MathMin(MathMax(MaxLot, 0.0), 100.0);
  }

void AddResult(long id, bool ok, long retcode, string ticket, double price, string msg)
  {
   if(g_resultCount >= MAX_RESULTS)
      return;
   if(g_results != "")
      g_results += ",";
   g_results += "{\"id\":" + IntegerToString(id)
                + ",\"ok\":" + (ok ? "1" : "0")
                + ",\"rc\":" + IntegerToString(retcode)
                + ",\"ticket\":\"" + JsonText(ticket) + "\""
                + ",\"price\":" + DoubleToString(price, 8)
                + ",\"msg\":\"" + JsonText(StringSubstr(msg, 0, 180)) + "\"}";
   g_resultCount++;
  }

ENUM_ORDER_TYPE_FILLING Filling(string sym)
  {
   long modes = SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);
   if((modes & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      return ORDER_FILLING_FOK;
   if((modes & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
  }

// One order line: id|SYMBOL|TYPE|volume|price|stoplimit|sl|tp|EXPIRY|expiresUtc|ageMs
void ExecuteOrder(string line)
  {
   string f[];
   if(StringSplit(line, '|', f) != 11)
      return;
   long id = StringToInteger(f[0]);
   if(id <= 0)
      return;

   // Once only. Marked BEFORE sending: a crash between here and the broker
   // loses this order; it can never place it twice.
   string mark = "NKT_O_" + IntegerToString(id);
   if(GlobalVariableCheck(mark))
     {
      AddResult(id, false, 0, "", 0, Msg("Lệnh này đã chạy một lần, bỏ qua.", "Already run once; skipped."));
      return;
     }
   GlobalVariableSet(mark, (double)TimeCurrent());

   if(StringToInteger(f[10]) > ORDER_MAX_AGE_MS)
     {
      AddResult(id, false, 0, "", 0, Msg("Lệnh quá 30 giây, không gửi.", "Order older than 30 seconds; not sent."));
      return;
     }
   if(!CanTrade())
     {
      AddResult(id, false, 0, "", 0, Msg("Giao dịch đang tắt trong EA hoặc MT5.", "Trading is off in the EA or in MT5."));
      return;
     }

   double volume = StringToDouble(f[3]);
   if(volume <= 0 || volume > LotCap() + 0.0000001)
     {
      AddResult(id, false, 0, "", 0, Msg("Vượt MaxLot của EA (" + DoubleToString(LotCap(), 2) + " lot).",
                                         "Above the EA's MaxLot (" + DoubleToString(LotCap(), 2) + " lot)."));
      return;
     }
   double sl = StringToDouble(f[6]);
   if(sl <= 0)
     {
      AddResult(id, false, 0, "", 0, Msg("Thiếu cắt lỗ, không gửi.", "No stop loss; not sent."));
      return;
     }

   string sym = ResolveSymbol(Clean(f[1]));
   if(sym == "")
     {
      AddResult(id, false, 0, "", 0, Msg("Sàn này không có " + f[1] + ".", "This broker does not offer " + f[1] + "."));
      return;
     }
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);

   // Round DOWN to the broker's step: never more than the reader asked for.
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   if(step > 0)
     {
      int vd = (int)MathMax(0.0, MathCeil(-MathLog10(step) - 0.0000001));
      volume = NormalizeDouble(MathFloor(volume / step + 0.0000001) * step, vd);
     }
   if(volume < vmin - 0.0000001 || (vmax > 0 && volume > vmax + 0.0000001))
     {
      AddResult(id, false, 0, "", 0, Msg("Khối lượng ngoài giới hạn của sàn (" + DoubleToString(vmin, 2) + "–" + DoubleToString(vmax, 2) + ").",
                                         "Volume outside the broker's limits (" + DoubleToString(vmin, 2) + "–" + DoubleToString(vmax, 2) + ")."));
      return;
     }

   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);
   req.symbol  = sym;
   req.volume  = volume;
   req.sl      = NormalizeDouble(sl, digits);
   double tp   = StringToDouble(f[7]);
   req.tp      = (tp > 0 ? NormalizeDouble(tp, digits) : 0);
   req.magic   = (ulong)Magic;
   req.comment = "NKT#" + IntegerToString(id);
   req.type_filling = Filling(sym);

   string type = f[2];
   bool pending = true;
   if(type == "BUY")
     { req.type = ORDER_TYPE_BUY; pending = false; }
   else if(type == "SELL")
     { req.type = ORDER_TYPE_SELL; pending = false; }
   else if(type == "BUY_LIMIT")
      req.type = ORDER_TYPE_BUY_LIMIT;
   else if(type == "SELL_LIMIT")
      req.type = ORDER_TYPE_SELL_LIMIT;
   else if(type == "BUY_STOP")
      req.type = ORDER_TYPE_BUY_STOP;
   else if(type == "SELL_STOP")
      req.type = ORDER_TYPE_SELL_STOP;
   else if(type == "BUY_STOP_LIMIT")
      req.type = ORDER_TYPE_BUY_STOP_LIMIT;
   else if(type == "SELL_STOP_LIMIT")
      req.type = ORDER_TYPE_SELL_STOP_LIMIT;
   else
     {
      AddResult(id, false, 0, "", 0, Msg("Loại lệnh lạ: " + type, "Unknown order type: " + type));
      return;
     }

   if(!pending)
     {
      MqlTick tick;
      if(!SymbolInfoTick(sym, tick) || tick.bid <= 0 || tick.ask <= 0)
        {
         AddResult(id, false, 0, "", 0, Msg("Chưa có giá " + sym + ".", "No price for " + sym + "."));
         return;
        }
      req.action    = TRADE_ACTION_DEAL;
      req.price     = (req.type == ORDER_TYPE_BUY ? tick.ask : tick.bid);
      req.deviation = (ulong)MathMax(Slippage, 0);
     }
   else
     {
      req.action = TRADE_ACTION_PENDING;
      req.price  = NormalizeDouble(StringToDouble(f[4]), digits);
      if(req.type == ORDER_TYPE_BUY_STOP_LIMIT || req.type == ORDER_TYPE_SELL_STOP_LIMIT)
         req.stoplimit = NormalizeDouble(StringToDouble(f[5]), digits);
      long modes = SymbolInfoInteger(sym, SYMBOL_EXPIRATION_MODE);
      string expiry = f[8];
      long need = SYMBOL_EXPIRATION_GTC;
      if(expiry == "DAY")
        {
         req.type_time = ORDER_TIME_DAY;
         need = SYMBOL_EXPIRATION_DAY;
        }
      else if(expiry == "SPECIFIED")
        {
         req.type_time  = ORDER_TIME_SPECIFIED;
         // The server sends UTC; MT5 wants the trade server's clock.
         req.expiration = (datetime)(StringToInteger(f[9]) + (long)(TimeTradeServer() - TimeGMT()));
         need = SYMBOL_EXPIRATION_SPECIFIED;
        }
      else
         req.type_time = ORDER_TIME_GTC;
      if((modes & need) != need)
        {
         AddResult(id, false, 0, "", 0, Msg("Sàn không cho kiểu hết hạn này với " + sym + ".",
                                            "The broker does not allow this expiry on " + sym + "."));
         return;
        }
     }

   // A netting account keeps one position per symbol and merges every deal
   // into it: a web SELL would close a long, a BUY would replace its stops.
   // This EA only opens, so it only trades on hedging accounts.
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
     {
      AddResult(id, false, 0, "", 0, Msg("Tài khoản netting: EA chỉ đặt lệnh trên tài khoản hedging.",
                                         "Netting account: the EA only places orders on a hedging account."));
      return;
     }

   ResetLastError();
   bool sent = OrderSend(req, res);
   bool ok = sent && (res.retcode == TRADE_RETCODE_DONE
                      || res.retcode == TRADE_RETCODE_PLACED
                      || res.retcode == TRADE_RETCODE_DONE_PARTIAL);
   string ticket = "";
   if(res.order > 0)
      ticket = IntegerToString((long)res.order);
   else if(res.deal > 0)
      ticket = IntegerToString((long)res.deal);
   string msg = res.comment;
   if(msg == "")
      msg = "retcode " + IntegerToString((long)res.retcode);
   if(!sent && res.retcode == 0)
      msg = Msg("Lỗi ", "Error ") + IntegerToString(GetLastError());
   AddResult(id, ok, (long)res.retcode, ticket, res.price, msg);
   Show(Msg("lệnh #" + IntegerToString(id) + ": ", "order #" + IntegerToString(id) + ": ") + msg);
  }

void Poll()
  {
   bool can = CanTrade();
   string body = "{\"v\":1,\"login\":" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN))
                 + ",\"allow\":" + (AllowTrading ? "1" : "0")
                 + ",\"trade\":" + (can ? "1" : "0")
                 + ",\"maxLot\":" + DoubleToString(LotCap(), 2)
                 + ",\"results\":[" + g_results + "]}";
   string response;
   int status = Post(OrdersUrl(), body, 5000, response);
   if(status != 200)
     {
      // Results stay queued and go with the next poll.
      Failed(status);
      return;
     }
   g_results = "";
   g_resultCount = 0;

   if(can)
      g_tradeLine = Msg("Nhận lệnh từ web: BẬT · tối đa ", "Orders from the web: ON · up to ") + DoubleToString(LotCap(), 2) + " lot";
   else
      g_tradeLine = Msg("Nhận lệnh từ web: MT5 đang chặn — bật nút Algo Trading và ô Allow Algo Trading của EA.",
                        "Orders from the web: blocked by MT5 — turn on Algo Trading and the EA's Allow Algo Trading box.");
   Render();

   string orders = JsonField(response, "orders");
   if(orders == "")
      return;
   string lines[];
   int n = StringSplit(orders, ';', lines);
   for(int i = 0; i < n; i++)
      if(lines[i] != "")
         ExecuteOrder(lines[i]);
  }

int OnInit()
  {
   ArrayResize(g_base, 0);
   ArrayResize(g_broker, 0);
   string parts[];
   int n = StringSplit(Symbols, ',', parts);
   for(int i = 0; i < n; i++)
      AddSymbol(parts[i]);
   if(StringLen(Token) < 20)
     {
      Show(Msg("chưa có mã kết nối. Lấy mã ở Cài đặt → Kết nối MT4/MT5 rồi dán vào ô Token.",
               "no connection token. Get one in Settings → MT4/MT5 connection and paste it into Token."));
      return(INIT_SUCCEEDED);
     }
   g_tradeLine = (AllowTrading
                  ? Msg("Nhận lệnh từ web: đang kết nối…", "Orders from the web: connecting…")
                  : Msg("Nhận lệnh từ web: TẮT (AllowTrading = false)", "Orders from the web: OFF (AllowTrading = false)"));
   // Orders want a one-second poll; prices alone are fine every five.
   EventSetTimer(AllowTrading ? 1 : 5);
   Show(Msg("đang kết nối…", "connecting…"));
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   Comment("");
  }

void OnTimer()
  {
   if(g_stopped)
      return;
   if(AllowTrading)
      Poll();
   if(!g_stopped && (!AllowTrading || g_tick % 5 == 0))
      Push();
   g_tick++;
  }

void OnTick()
  {
  }
