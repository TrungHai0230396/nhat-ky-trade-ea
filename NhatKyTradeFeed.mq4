//+------------------------------------------------------------------+
//| NhatKyTradeFeed.mq4                                               |
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
#property version   "1.18"
#property description "Sends prices, candles, the account's balance, equity and number, and its open orders to Nhật Ký Trade."
#property description "Places orders from the web only with AllowTrading = true. Never modifies or closes one."
#property strict

input string Token        = "";                                                  // Token (Cài đặt → Kết nối MT4/MT5)
input string Symbols      = "XAUUSD,EURUSD,GBPUSD,USDJPY,AUDUSD,USDCAD,USDCHF,NZDUSD"; // Symbols
input bool   AllowTrading = false;                                               // AllowTrading (nhận lệnh từ web)
input double MaxLot       = 0.10;                                                // MaxLot (lot tối đa mỗi lệnh)
input int    Slippage     = 20;                                                  // Slippage (points, lệnh thị trường)
input int    Magic        = 20261110;                                            // Magic
input string Lang         = "vi";                                                // vi | en
input string FeedUrl      = "https://nhatkytrade.com/api/mt5/feed";                                        // Feed URL

#define MAX_SYMBOLS 20
#define FULL_BARS   300
#define HIST_MAX_BARS 20000  // one series for the backtest page, at most
#define TF_COUNT    4
#define ORDER_MAX_AGE_MS 30000
#define MAX_RESULTS 20
#define OFFSET_KEY  "NKT_OFFSET"

ENUM_TIMEFRAMES g_tfs[TF_COUNT]     = {PERIOD_M15, PERIOD_H1, PERIOD_H4, PERIOD_D1};
string          g_tfNames[TF_COUNT] = {"M15", "H1", "H4", "D1"};

string g_base[];       // app names: XAUUSD
string g_broker[];     // this broker's names: XAUUSDm ("" when not offered)
string g_need  = "*";  // series to resend in full; "*" = all of them
string g_jsince = "";  // auto-journal: broker time to read closed orders from; "" = off
int    g_round = 0;
int    g_tick  = 0;
bool   g_stopped = false;
string g_line  = "";   // what the last feed push said
string g_tradeLine = "";
string g_results = ""; // order results not yet accepted by the server, JSON objects
int    g_resultCount = 0;

// Broker server time minus UTC, in seconds. See TrackServerClock().
long     g_offset = 0;
bool     g_offsetKnown = false;  // some value is in g_offset
bool     g_offsetSure  = false;  // taken from a moving clock in this session
datetime g_lastServer   = 0;     // last TimeCurrent() seen
datetime g_lastServerAt = 0;     // TimeLocal() when it last moved; 0 = not seen moving

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
   // An empty value ("hist":"") must read as "": StringSubstr with a length of
   // 0 returns the REST of the string, so before 1.18 an empty "hist" read as
   // "} and dropped the history request waiting in the EA one push after it
   // came (owner's MT4, 12/11/2026), and an empty "jsince" read as non-empty
   // and sent closed trades while auto-journal was off.
   if(end <= start)
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
//
//
// THE EA DOES NOT OPEN OR SCROLL A CHART. 1.17 did: it opened a chart of the
// pair and scrolled it to the oldest bar every push, as Home does, so MT4
// would ask the broker for older bars. Measured on the owner's MT4
// (12/11/2026): two minutes of that, not one bar more - 1008 H1 gold bars,
// the oldest 11/09/2026, while the broker's own history starts 28/03/2025.
// A chart scrolled from code fetches nothing; only the reader's own Home
// press does, so the page and the status line ask for that instead.
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
   // Only a real request replaces the one waiting: "SYMBOL|TF|COUNT".
   string parts[];
   if(StringSplit(req, '|', parts) != 3)
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
   // Tools > Options > Charts > "Max bars in chart": MT4 keeps no more than
   // that, so waiting for more would only run out the clock.
   int cap = (int)TerminalInfoInteger(TERMINAL_MAXBARS);
   if(cap > 0 && count > cap)
      count = cap;
   string sym = parts[0];
   MqlRates rates[];
   ResetLastError();
   int got = CopyRates(sym, g_tfs[k], 0, count, rates);
   bool loading = GetLastError() == 4066;  // ERR_HISTORY_WILL_UPDATED: MT4 is fetching it
   g_histTries++;
   if(got > 0 && got == g_histLast && !loading)
      g_histSame++;
   else
      g_histSame = 0;
   g_histLast = got;
   if(got < count && g_histSame < HIST_STABLE_ROUNDS && g_histTries < HIST_MAX_TRIES)
     {
      string n = IntegerToString(got > 0 ? got : 0);
      Show(Msg("đang chờ MT4 tải lịch sử " + sym + " " + parts[1] + " · " + n + " nến",
               "waiting for MT4 to load " + sym + " " + parts[1] + " history · " + n + " bars"));
      return;
     }
   g_histReq = "";
   Print("history ", sym, " ", parts[1], ": sending ", got, " of ", count, " bars");
   if(got > 0)
      SendRates(sym, parts[1], count, rates, got);
  }

void SendRates(string sym, string tfName, int count, MqlRates &rates[], int got)
  {
   int digits = Digits4(sym);
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
   string body = "{\"v\":1,\"pf\":4,\"offset\":" + IntegerToString(g_offset)
                 + ",\"s\":\"" + sym + "\",\"tf\":\"" + tfName
                 + "\",\"d\":" + IntegerToString(digits)
                 + ",\"r\":[" + rows + "]}";
   string response;
   int status = Post(HistoryUrl(), body, 30000, response);
   if(status != 200)
      Failed(status);
   else if(got < count)
      // All MT4 holds. Older bars come only when the reader scrolls a chart back.
      Show(Msg("đã gửi lịch sử " + sym + " " + tfName + " · " + IntegerToString(got) + " nến - MT4 chỉ có chừng này. Muốn thêm: mở biểu đồ " + sym + " " + tfName + ", bấm Home vài lần, rồi Tải lại trên web",
               "history sent " + sym + " " + tfName + " · " + IntegerToString(got) + " bars - all MT4 has. For more: open a " + sym + " " + tfName + " chart, press Home a few times, then Reload on the web"));
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

int Digits4(string sym)
  {
   return (int)MarketInfo(sym, MODE_DIGITS);
  }

// Rounded to the quarter hour, as the server does (feed-store.ts snapOffset).
long Snap(long seconds)
  {
   return (long)MathRound(seconds / 900.0) * 900;
  }

// MT4 has no TimeTradeServer(): TimeCurrent() is the time of the last quote,
// and it stands still on weekends. Read the offset only from a clock seen
// moving in the last five minutes; otherwise keep the last good one.
void TrackServerClock()
  {
   datetime now = TimeCurrent();
   if(now != g_lastServer)
     {
      if(g_lastServer != 0)
         g_lastServerAt = TimeLocal();
      g_lastServer = now;
     }
   bool moving = (g_lastServerAt > 0 && TimeLocal() - g_lastServerAt <= 300);
   if(moving)
     {
      long off = Snap((long)(now - TimeGMT()));
      // A different offset (a DST change, or a guess made on a weekend):
      // every candle already sent is an hour out, so send them all again.
      if(g_offsetKnown && off != g_offset)
         g_need = "*";
      g_offset = off;
      g_offsetKnown = true;
      g_offsetSure = true;
      GlobalVariableSet(OFFSET_KEY, (double)off);
      return;
     }
   if(g_offsetKnown)
      return;
   if(GlobalVariableCheck(OFFSET_KEY))
      g_offset = (long)GlobalVariableGet(OFFSET_KEY);
   else
      g_offset = Snap((long)(now - TimeGMT()));
   if(g_offset < -43200 || g_offset > 50400)
      g_offset = 0;
   g_offsetKnown = true;
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
      // MT4 reports a URL missing from the allowed list as 4060; 4014 as in MT5.
      if(err == 4060 || err == 4014)
         Show(Msg("MT4 chưa cho phép gửi tới " + Host() + ". Vào Tools → Options → Expert Advisors, bật \"Allow WebRequest for listed URL\" và thêm " + Host() + ".",
                  "MT4 does not allow requests to " + Host() + " yet. Go to Tools → Options → Expert Advisors, tick \"Allow WebRequest for listed URL\" and add " + Host() + "."));
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

// Every open market order, as the journal wants it. Pending orders are not trades yet.
string OpenPositions()
  {
   string out = "";
   int total = OrdersTotal();
   for(int i = 0; i < total && i < 200; i++)
     {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      int type = OrderType();
      if(type != OP_BUY && type != OP_SELL)
         continue;
      string psym = OrderSymbol();
      int pd = Digits4(psym);
      if(out != "")
         out += ",";
      out += "{\"id\":" + IntegerToString(OrderTicket())
             + ",\"s\":\"" + JsonText(psym) + "\""
             + ",\"t\":" + (type == OP_BUY ? "0" : "1")
             + ",\"v\":" + DoubleToString(OrderLots(), 2)
             + ",\"p\":" + DoubleToString(OrderOpenPrice(), pd)
             + ",\"o\":" + IntegerToString((long)OrderOpenTime())
             + ",\"sl\":" + DoubleToString(OrderStopLoss(), pd)
             + ",\"tp\":" + DoubleToString(OrderTakeProfit(), pd) + "}";
     }
   return out;
  }

// Every open position and pending order, all symbols, for the chart page to
// draw (payload "work"). OrderType() is already the wire's type number.
string WorkingOrders()
  {
   string out = "";
   int total = OrdersTotal();
   for(int i = 0; i < total && i < 200; i++)
     {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      int type = OrderType();
      if(type < OP_BUY || type > OP_SELLSTOP)
         continue;
      string ws = OrderSymbol();
      int wd = Digits4(ws);
      if(out != "")
         out += ",";
      out += "{\"id\":" + IntegerToString(OrderTicket())
             + ",\"s\":\"" + JsonText(ws) + "\""
             + ",\"t\":" + IntegerToString(type)
             + ",\"v\":" + DoubleToString(OrderLots(), 2)
             + ",\"p\":" + DoubleToString(OrderOpenPrice(), wd)
             + ",\"sl\":" + DoubleToString(OrderStopLoss(), wd)
             + ",\"tp\":" + DoubleToString(OrderTakeProfit(), wd) + "}";
     }
   return out;
  }

// The OLDEST 50 market orders closed since the given broker time, oldest
// first. The server moves since to the newest one it receives, so taking
// the oldest never skips any when more than 50 are waiting; the History tab's
// own order is not time order, hence the sort.
string ClosedPositions(datetime since)
  {
   int tickets[];
   datetime times[];
   int n = 0;
   int total = OrdersHistoryTotal();
   for(int i = 0; i < total; i++)
     {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY))
         continue;
      int type = OrderType();
      if(type != OP_BUY && type != OP_SELL)
         continue;
      datetime closed = OrderCloseTime();
      if(closed <= 0 || closed < since || OrderOpenTime() <= 0)
         continue;
      ArrayResize(tickets, n + 1, 256);
      ArrayResize(times, n + 1, 256);
      tickets[n] = OrderTicket();
      times[n] = closed;
      n++;
     }
   string out = "";
   for(int k = 0; k < 50 && k < n; k++)
     {
      int best = -1;
      for(int j = 0; j < n; j++)
         if(tickets[j] > 0 && (best < 0 || times[j] < times[best]))
            best = j;
      if(best < 0)
         break;
      int tk = tickets[best];
      tickets[best] = 0;
      if(!OrderSelect(tk, SELECT_BY_TICKET, MODE_HISTORY))
         continue;
      int type = OrderType();
      string dsym = OrderSymbol();
      int pd = Digits4(dsym);
      if(out != "")
         out += ",";
      out += "{\"id\":" + IntegerToString(OrderTicket())
             + ",\"s\":\"" + JsonText(dsym) + "\""
             + ",\"t\":" + (type == OP_BUY ? "0" : "1")
             + ",\"v\":" + DoubleToString(OrderLots(), 2)
             + ",\"p\":" + DoubleToString(OrderOpenPrice(), pd)
             + ",\"o\":" + IntegerToString((long)OrderOpenTime())
             + ",\"x\":" + DoubleToString(OrderClosePrice(), pd)
             + ",\"c\":" + IntegerToString((long)OrderCloseTime())
             + ",\"pr\":" + DoubleToString(OrderProfit(), 2)
             + ",\"sw\":" + DoubleToString(OrderSwap(), 2)
             + ",\"cm\":" + DoubleToString(OrderCommission(), 2)
             + ",\"fee\":0"
             + ",\"sl\":" + DoubleToString(OrderStopLoss(), pd)
             + ",\"tp\":" + DoubleToString(OrderTakeProfit(), pd) + "}";
     }
   return out;
  }

void Push()
  {
   TrackServerClock();
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
      int digits = Digits4(sym);
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
      // The broker's own contract terms, in the account's currency. MT4 has one
      // tick value for both directions, so it goes out as both.
      double tv = MarketInfo(sym, MODE_TICKVALUE);
      if(specs != "")
         specs += ",";
      specs += "{\"s\":\"" + sym + "\""
               + ",\"ts\":" + DoubleToString(MarketInfo(sym, MODE_TICKSIZE), 8)
               + ",\"tvl\":" + DoubleToString(tv, 8)
               + ",\"tvp\":" + DoubleToString(tv, 8)
               + ",\"cs\":" + DoubleToString(MarketInfo(sym, MODE_LOTSIZE), 4)
               + ",\"vmin\":" + DoubleToString(MarketInfo(sym, MODE_MINLOT), 4)
               + ",\"vstep\":" + DoubleToString(MarketInfo(sym, MODE_LOTSTEP), 4)
               + ",\"vmax\":" + DoubleToString(MarketInfo(sym, MODE_MAXLOT), 4) + "}";
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

   // Auto-journal, on the candle rounds, only while the reader has it on, and
   // only once the offset is sure: a journal row keeps the time it was given.
   string journal = "";
   if(withBars && g_jsince != "" && g_offsetSure)
      journal = ",\"open\":[" + OpenPositions() + "]"
                + ",\"closed\":[" + ClosedPositions((datetime)StringToInteger(g_jsince)) + "]";

   // What is working now, on the same rounds, auto-journal or not.
   string work = "";
   if(withBars)
      work = ",\"work\":[" + WorkingOrders() + "]";

   string body = "{\"v\":1,\"pf\":4,\"server\":\"" + JsonText(AccountInfoString(ACCOUNT_SERVER))
                 + "\",\"login\":" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN))
                 + ",\"offset\":" + IntegerToString(g_offset)
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

// Every switch between this EA and the broker: the EA's own input, MT4's
// AutoTrading button, the EA's "Allow live trading" box, and the account
// (an investor-password login cannot trade). Not IsTradeAllowed(): it also
// answers false while the trade context is busy, which is not a switch.
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

void AddResult(long id, bool ok, long code, string ticket, double price, string msg)
  {
   if(g_resultCount >= MAX_RESULTS)
      return;
   if(g_results != "")
      g_results += ",";
   g_results += "{\"id\":" + IntegerToString(id)
                + ",\"ok\":" + (ok ? "1" : "0")
                + ",\"rc\":" + IntegerToString(code)
                + ",\"ticket\":\"" + JsonText(ticket) + "\""
                + ",\"price\":" + DoubleToString(price, 8)
                + ",\"msg\":\"" + JsonText(StringSubstr(msg, 0, 180)) + "\"}";
   g_resultCount++;
  }

// MT4's trade errors a reader can act on, in words. The rest keep their number.
string TradeError(int err)
  {
   switch(err)
     {
      case 129: return Msg("Giá không hợp lệ (129).", "Invalid price (129).");
      case 130: return Msg("Cắt lỗ / chốt lời quá gần giá hoặc sai phía (130).", "Stops too close to the price or on the wrong side (130).");
      case 131: return Msg("Khối lượng không hợp lệ (131).", "Invalid volume (131).");
      case 132: return Msg("Thị trường đang đóng (132).", "Market is closed (132).");
      case 133: return Msg("Sàn đang chặn giao dịch mã này (133).", "Trading is disabled for this symbol (133).");
      case 134: return Msg("Không đủ ký quỹ (134).", "Not enough money (134).");
      case 135: return Msg("Giá đã đổi (135).", "Price changed (135).");
      case 136: return Msg("Không có giá (136).", "Off quotes (136).");
      case 138: return Msg("Sàn báo giá lại (138).", "Requote (138).");
      case 146: return Msg("MT4 đang bận gửi lệnh khác (146).", "The trade context is busy (146).");
      case 147: return Msg("Sàn không cho đặt hạn cho lệnh chờ (147).", "The broker does not allow expiries (147).");
      case 148: return Msg("Quá số lệnh sàn cho phép (148).", "Too many orders (148).");
     }
   return Msg("Lỗi ", "Error ") + IntegerToString(err);
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
      AddResult(id, false, 0, "", 0, Msg("Giao dịch đang tắt trong EA hoặc MT4.", "Trading is off in the EA or in MT4."));
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

   string type = f[2];
   int cmd = -1;
   bool pending = true;
   if(type == "BUY")
     { cmd = OP_BUY; pending = false; }
   else if(type == "SELL")
     { cmd = OP_SELL; pending = false; }
   else if(type == "BUY_LIMIT")
      cmd = OP_BUYLIMIT;
   else if(type == "SELL_LIMIT")
      cmd = OP_SELLLIMIT;
   else if(type == "BUY_STOP")
      cmd = OP_BUYSTOP;
   else if(type == "SELL_STOP")
      cmd = OP_SELLSTOP;
   else if(type == "BUY_STOP_LIMIT" || type == "SELL_STOP_LIMIT")
     {
      AddResult(id, false, 0, "", 0, Msg("MT4 không có lệnh Stop Limit.", "MT4 has no Stop Limit orders."));
      return;
     }
   else
     {
      AddResult(id, false, 0, "", 0, Msg("Loại lệnh lạ: " + type, "Unknown order type: " + type));
      return;
     }

   string sym = ResolveSymbol(Clean(f[1]));
   if(sym == "")
     {
      AddResult(id, false, 0, "", 0, Msg("Sàn này không có " + f[1] + ".", "This broker does not offer " + f[1] + "."));
      return;
     }
   int digits = Digits4(sym);

   // Round DOWN to the broker's step: never more than the reader asked for.
   double step = MarketInfo(sym, MODE_LOTSTEP);
   double vmin = MarketInfo(sym, MODE_MINLOT);
   double vmax = MarketInfo(sym, MODE_MAXLOT);
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

   double price = 0;
   datetime expiration = 0;
   if(!pending)
     {
      RefreshRates();
      price = (cmd == OP_BUY ? MarketInfo(sym, MODE_ASK) : MarketInfo(sym, MODE_BID));
      if(price <= 0)
        {
         AddResult(id, false, 0, "", 0, Msg("Chưa có giá " + sym + ".", "No price for " + sym + "."));
         return;
        }
     }
   else
     {
      price = NormalizeDouble(StringToDouble(f[4]), digits);
      string expiry = f[8];
      if(expiry == "DAY")
        {
         // MT4 has no "today" order: expire at the end of the server's day.
         datetime now = TimeCurrent();
         expiration = now - (now % 86400) + 86400;
        }
      else if(expiry == "SPECIFIED")
        {
         // The server sends UTC; MT4 wants the trade server's clock, and the
         // offset is only known once that clock has been seen moving.
         if(!g_offsetSure)
           {
            AddResult(id, false, 0, "", 0, Msg("Chưa xác định được giờ máy chủ của sàn, chưa đặt được hạn giờ. Thử lại sau ít phút.",
                                               "The broker's server time is not known yet, so no expiry time can be set. Try again in a few minutes."));
            return;
           }
         expiration = (datetime)(StringToInteger(f[9]) + g_offset);
        }
     }

   double tp = StringToDouble(f[7]);
   ResetLastError();
   int ticket = OrderSend(sym, cmd, volume, price, (int)MathMax(Slippage, 0),
                          NormalizeDouble(sl, digits), (tp > 0 ? NormalizeDouble(tp, digits) : 0),
                          "NKT#" + IntegerToString(id), Magic, expiration, clrNONE);
   if(ticket < 0)
     {
      int err = GetLastError();
      string why = TradeError(err);
      AddResult(id, false, err, "", 0, why);
      Show(Msg("lệnh #" + IntegerToString(id) + ": ", "order #" + IntegerToString(id) + ": ") + why);
      return;
     }
   double fill = price;
   if(OrderSelect(ticket, SELECT_BY_TICKET))
      fill = OrderOpenPrice();
   string done = (pending ? Msg("Đã đặt lệnh chờ", "Pending order placed") : Msg("Đã khớp", "Filled"));
   AddResult(id, true, 0, IntegerToString(ticket), fill, done);
   Show(Msg("lệnh #" + IntegerToString(id) + ": ", "order #" + IntegerToString(id) + ": ") + done);
  }

void Poll()
  {
   bool can = CanTrade();
   string body = "{\"v\":1,\"pf\":4,\"login\":" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN))
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
      g_tradeLine = Msg("Nhận lệnh từ web: MT4 đang chặn — bật nút AutoTrading và ô Allow live trading của EA.",
                        "Orders from the web: blocked by MT4 — turn on AutoTrading and the EA's Allow live trading box.");
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
   // Before Poll: an order with an expiry time needs the server's offset.
   TrackServerClock();
   if(AllowTrading)
      Poll();
   if(!g_stopped && (!AllowTrading || g_tick % 5 == 0))
      Push();
   g_tick++;
  }

// A tick on this chart means TimeCurrent() is the server's clock right now.
void OnTick()
  {
   g_lastServer = TimeCurrent();
   g_lastServerAt = TimeLocal();
  }
