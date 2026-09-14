//+------------------------------------------------------------------+
//| IronHawk SMC Trade Zones M5.mq5                                  |
//| Intelligent Structured Market Analysis Indicator for MT5         |
//| Version 1.0 - Production Ready                                   |
//+------------------------------------------------------------------+
#property copyright "IronHawk Trading Systems"
#property link      "https://github.com/cashnana/ironhawk-smc-trade-zones"
#property version   "1.00"
#property strict
#property indicator_chart_window

#include <Trade\SymbolInfo.mqh>
#include <Trade\PositionInfo.mqh>

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                 |
//+------------------------------------------------------------------+

// Core Configuration
input int HistoryBars = 500;              // Number of M5 bars to scan
input int MinimumDailySignals = 2;        // Minimum daily organic signals
input int MaximumDisplayedSetups = 10;    // Max zones displayed on chart
input int RecentSetupCount = 5;           // Recent completed setups to track

// Time Settings (Server Time)
input int RetailFirstSignalHour = 9;      // First retail signal time (hour)
input int RetailSecondSignalHour = 14;    // Second retail signal time (hour)

// Risk Management
input double RetailStopATR = 1.5;         // Stop Loss ATR multiplier
input double RetailTargetR = 2.5;         // TP2 Risk-Reward ratio
input double OrganicStopATR = 1.2;        // Organic signal Stop Loss
input double OrganicTargetR = 3.0;        // Organic signal TP2

// Technical Indicators
input int RSI_Period = 14;                // RSI period
input int MACD_Fast = 12;                 // MACD fast MA
input int MACD_Slow = 26;                 // MACD slow MA
input int MACD_Signal = 9;                // MACD signal line
input int ATR_Period = 14;                // ATR period
input int EMA_20_Period = 20;             // EMA 20
input int EMA_50_Period = 50;             // EMA 50

// Smart Detection Settings
input double SwingPointSensitivity = 0.75; // 0.5-1.5, higher = more sensitive
input double LiquiditySweepPercent = 0.5;  // % of recent swing for sweep
input double FVG_Minimum_Pips = 5;         // Minimum FVG size
input int MinBarsForStructure = 3;         // Min bars to confirm structure

// Alert Settings
input bool EnableAlerts = true;
input bool EnablePushNotifications = false;
input bool EnableEmailAlerts = false;
input bool EnableCSVJournal = false;
input string CSVFilePath = "IronHawk_Journal.csv";

// Display Settings
input color BullishSetupColor = clrGreen;
input color BearishSetupColor = clrRed;
input color FVGColor = clrCyan;
input color OrderBlockColor = clrYellow;
input color LiquidityColor = clrMagenta;
input int LabelFontSize = 10;

//+------------------------------------------------------------------+
//| STRUCTURE DEFINITIONS                                            |
//+------------------------------------------------------------------+

struct PriceLevel
{
   double price;
   datetime time;
   int barIndex;
};

struct Setup
{
   int setupID;
   datetime createdTime;
   datetime entryTime;
   int entryBar;
   bool isBullish;
   string setupType;           // "ORGANIC" or "RETAIL"
   string setupState;          // ARMED, ACTIVE, TP, SL, EXPIRED, INVALIDATED, AMBIGUOUS
   
   double entryLevel;
   double stopLoss;
   double tp1;
   double tp2;
   
   PriceLevel swingHigh;
   PriceLevel swingLow;
   PriceLevel liquiditySweep;
   
   double riskReward;
   double atrValue;
   
   bool hasLiquiditySweep;
   bool hasFVG;
   bool hasOrderBlock;
   bool bosCCh;
   
   int rsiValue;
   double macdValue;
   double macdSignal;
   bool emaAlignment;
   
   double outcome;             // Profit/Loss in pips
   string outcomeState;        // WON, LOSS, NEUTRAL, PENDING
};

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                 |
//+------------------------------------------------------------------+

Setup activeSetups[1000];
int setupCount = 0;
Setup recentCompletedSetups[10];
int recentSetupIndex = 0;
datetime lastRetailSignalTime = 0;
int dailySignalCount = 0;
datetime lastDayReset = 0;

double dailyHigh = 0, dailyLow = 0;
string currentMarketStructure = "UNDEFINED";
string currentBias = "NEUTRAL";

int totalScannedBars = 0;
int totalSetupsGenerated = 0;

//+------------------------------------------------------------------+
//| EXPERT INITIALIZATION                                            |
//+------------------------------------------------------------------+

int OnInit()
{
   if(Period() != PERIOD_M5)
   {
      Alert("IronHawk SMC Zones works ONLY on M5 timeframe!");
      return INIT_FAILED;
   }

   // Initialize CSV journal if enabled
   if(EnableCSVJournal)
   {
      int fileHandle = FileOpen(CSVFilePath, FILE_WRITE | FILE_CSV);
      if(fileHandle == INVALID_HANDLE)
      {
         Print("Failed to create CSV journal");
         return INIT_FAILED;
      }
      FileWrite(fileHandle, "DateTime", "SetupType", "Direction", "EntryPrice", 
                "StopLoss", "TP1", "TP2", "SetupState", "Outcome", "Risk:Reward");
      FileClose(fileHandle);
   }

   Print("IronHawk SMC Trade Zones M5 initialized successfully");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| EXPERT DEINITIALIZATION                                          |
//+------------------------------------------------------------------+

void OnDeinit(const int reason)
{
   ObjectsDeleteAll();
   Print("IronHawk SMC Trade Zones terminated");
}

//+------------------------------------------------------------------+
//| MAIN CALCULATION FUNCTION                                        |
//+------------------------------------------------------------------+

int OnCalculate(const int rates_total, const int prev_calculated, const datetime &time[], 
                const double &open[], const double &high[], const double &low[], 
                const double &close[], const long &tick_volume[], const long &volume[], 
                const int &spread[])
{
   if(rates_total < HistoryBars + 50)
      return rates_total;

   // Reset daily count if new day
   if(TimeDayOfWeek(TimeCurrent()) != TimeDayOfWeek(lastDayReset))
   {
      dailySignalCount = 0;
      lastDayReset = TimeCurrent();
      Print("Daily signal count reset: ", TimeCurrent());
   }

   // Main analysis loop
   int barsToAnalyze = MathMin(HistoryBars, rates_total);
   
   for(int i = 1; i < barsToAnalyze; i++)
   {
      // Scan for organic SMC setups
      ScanForOrganicSetups(i, rates_total, high, low, close, open);
      
      // Retail frequency mode (fallback)
      if(dailySignalCount < MinimumDailySignals)
      {
         ScanForRetailSetups(i, rates_total, high, low, close, open);
      }
   }

   // Update existing setups
   UpdateSetups(rates_total, close);
   
   // Display zones and information
   DisplaySetups(rates_total, high, low, close);
   DisplayMarketStructure(rates_total, high, low, close);
   
   totalScannedBars = barsToAnalyze;
   
   return rates_total;
}

//+------------------------------------------------------------------+
//| SCAN FOR ORGANIC SMC SETUPS                                      |
//+------------------------------------------------------------------+

void ScanForOrganicSetups(int barIndex, int rates_total, const double &high[], 
                          const double &low[], const double &close[], const double &open[])
{
   // Identify swing points
   PriceLevel swingHigh = {0, 0, -1};
   PriceLevel swingLow = {0, 0, -1};
   
   double sh = IsSwingHigh(barIndex, high, low);
   if(sh > 0)
   {
      swingHigh.price = sh;
      swingHigh.time = Time[barIndex];
      swingHigh.barIndex = barIndex;
   }
   
   double sl = IsSwingLow(barIndex, high, low);
   if(sl > 0)
   {
      swingLow.price = sl;
      swingLow.time = Time[barIndex];
      swingLow.barIndex = barIndex;
   }

   // Check for liquidity sweeps
   bool liquiditySweepBullish = CheckLiquiditySweep(barIndex, high, low, swingLow, true);
   bool liquiditySweepBearish = CheckLiquiditySweep(barIndex, high, low, swingHigh, false);

   // Detect BOS/CHoCH events
   bool bosCCh = DetectBOSCHoCH(barIndex, high, low, close);

   // Check for FVG (Fair Value Gaps)
   bool fvgExists = DetectFVG(barIndex, high, low);

   // Identify Order Blocks
   bool orderBlockExists = DetectOrderBlock(barIndex, high, low, close, open);

   // Multi-indicator confirmation
   bool rsiConfirm = CheckRSI(barIndex);
   bool macdConfirm = CheckMACD(barIndex);
   bool emaAlign = CheckEMAAlignment(barIndex);

   // Create setup if all conditions met
   if((liquiditySweepBullish || liquiditySweepBearish) && bosCCh && (fvgExists || orderBlockExists))
   {
      Setup newSetup = CreateSetup(barIndex, liquiditySweepBullish, "ORGANIC", 
                                   swingHigh, swingLow, high, low, close);
      
      if(newSetup.riskReward >= 1.5) // Minimum risk-reward filter
      {
         AddSetup(newSetup);
         dailySignalCount++;
         totalSetupsGenerated++;
         
         if(EnableAlerts)
            SendAlert("ORGANIC SETUP: " + (liquiditySweepBullish ? "BULLISH" : "BEARISH") + 
                     " | Entry: " + DoubleToString(newSetup.entryLevel, _Digits) + 
                     " | R:R: " + DoubleToString(newSetup.riskReward, 2));
      }
   }
}

//+------------------------------------------------------------------+
//| SCAN FOR RETAIL SETUPS (FALLBACK)                               |
//+------------------------------------------------------------------+

void ScanForRetailSetups(int barIndex, int rates_total, const double &high[], 
                         const double &low[], const double &close[], const double &open[])
{
   // Only generate retail signals at scheduled times
   MqlDateTime timeStruct;
   TimeToStruct(Time[barIndex], timeStruct);
   
   if((timeStruct.hour != RetailFirstSignalHour && timeStruct.hour != RetailSecondSignalHour) ||
      timeStruct.min != 0)
      return;

   if(Time[barIndex] == lastRetailSignalTime)
      return;

   // Majority vote from EMA 20/50, MACD, RSI
   int bullishVotes = 0;
   
   if(CheckEMAAlignment(barIndex))
      bullishVotes++;
   if(CheckMACD(barIndex))
      bullishVotes++;
   if(CheckRSI(barIndex))
      bullishVotes++;

   if(bullishVotes >= 2) // At least 2 out of 3 indicators agree
   {
      bool isBullish = (bullishVotes > 1);
      
      Setup retailSetup = CreateRetailSetup(barIndex, isBullish, high, low, close);
      AddSetup(retailSetup);
      dailySignalCount++;
      lastRetailSignalTime = Time[barIndex];
      
      if(EnableAlerts)
         SendAlert("RETAIL SETUP: " + (isBullish ? "BULLISH" : "BEARISH") + 
                  " | Entry: " + DoubleToString(retailSetup.entryLevel, _Digits));
   }
}

//+------------------------------------------------------------------+
//| SETUP CREATION FUNCTIONS                                         |
//+------------------------------------------------------------------+

Setup CreateSetup(int barIndex, bool isBullish, string setupType, 
                  PriceLevel swingHigh, PriceLevel swingLow, 
                  const double &high[], const double &low[], const double &close[])
{
   Setup setup;
   setup.setupID = setupCount++;
   setup.createdTime = Time[barIndex];
   setup.entryBar = barIndex;
   setup.isBullish = isBullish;
   setup.setupType = setupType;
   setup.setupState = "ARMED";
   setup.swingHigh = swingHigh;
   setup.swingLow = swingLow;
   
   double atr = iATR(Symbol(), PERIOD_M5, ATR_Period, barIndex);
   setup.atrValue = atr;
   
   if(isBullish)
   {
      setup.entryLevel = high[barIndex] + (2 * Point());
      setup.stopLoss = swingLow.price - (setupType == "ORGANIC" ? OrganicStopATR : RetailStopATR) * atr;
      double riskPips = (setup.entryLevel - setup.stopLoss) / Point();
      double targetR = (setupType == "ORGANIC" ? OrganicTargetR : RetailTargetR);
      setup.tp1 = setup.entryLevel + (riskPips * 1.5 * Point());
      setup.tp2 = setup.entryLevel + (riskPips * targetR * Point());
      setup.riskReward = (setup.tp2 - setup.entryLevel) / (setup.entryLevel - setup.stopLoss);
   }
   else
   {
      setup.entryLevel = low[barIndex] - (2 * Point());
      setup.stopLoss = swingHigh.price + (setupType == "ORGANIC" ? OrganicStopATR : RetailStopATR) * atr;
      double riskPips = (setup.stopLoss - setup.entryLevel) / Point();
      double targetR = (setupType == "ORGANIC" ? OrganicTargetR : RetailTargetR);
      setup.tp1 = setup.entryLevel - (riskPips * 1.5 * Point());
      setup.tp2 = setup.entryLevel - (riskPips * targetR * Point());
      setup.riskReward = (setup.entryLevel - setup.tp2) / (setup.stopLoss - setup.entryLevel);
   }
   
   // Indicator values
   setup.rsiValue = iRSI(Symbol(), PERIOD_M5, RSI_Period, barIndex);
   double macd, macdSignal;
   GetMACD(barIndex, macd, macdSignal);
   setup.macdValue = macd;
   setup.macdSignal = macdSignal;
   setup.emaAlignment = CheckEMAAlignment(barIndex);
   
   setup.hasLiquiditySweep = true;
   setup.hasFVG = DetectFVG(barIndex, high, low);
   setup.hasOrderBlock = DetectOrderBlock(barIndex, high, low, close, open);
   setup.bosCCh = true;
   
   return setup;
}

Setup CreateRetailSetup(int barIndex, bool isBullish, const double &high[], 
                        const double &low[], const double &close[])
{
   Setup setup;
   setup.setupID = setupCount++;
   setup.createdTime = Time[barIndex];
   setup.entryBar = barIndex;
   setup.isBullish = isBullish;
   setup.setupType = "RETAIL";
   setup.setupState = "ARMED";
   
   double atr = iATR(Symbol(), PERIOD_M5, ATR_Period, barIndex);
   setup.atrValue = atr;
   
   if(isBullish)
   {
      setup.entryLevel = high[barIndex] + Point();
      setup.stopLoss = setup.entryLevel - (RetailStopATR * atr);
      double riskPips = (setup.entryLevel - setup.stopLoss) / Point();
      setup.tp1 = setup.entryLevel + (riskPips * 1.5 * Point());
      setup.tp2 = setup.entryLevel + (riskPips * RetailTargetR * Point());
   }
   else
   {
      setup.entryLevel = low[barIndex] - Point();
      setup.stopLoss = setup.entryLevel + (RetailStopATR * atr);
      double riskPips = (setup.stopLoss - setup.entryLevel) / Point();
      setup.tp1 = setup.entryLevel - (riskPips * 1.5 * Point());
      setup.tp2 = setup.entryLevel - (riskPips * RetailTargetR * Point());
   }
   
   setup.riskReward = isBullish ? 
      (setup.tp2 - setup.entryLevel) / (setup.entryLevel - setup.stopLoss) :
      (setup.entryLevel - setup.tp2) / (setup.stopLoss - setup.entryLevel);
   
   setup.rsiValue = iRSI(Symbol(), PERIOD_M5, RSI_Period, barIndex);
   double macd, macdSignal;
   GetMACD(barIndex, macd, macdSignal);
   setup.macdValue = macd;
   setup.macdSignal = macdSignal;
   setup.emaAlignment = CheckEMAAlignment(barIndex);
   
   return setup;
}

//+------------------------------------------------------------------+
//| DETECTION FUNCTIONS                                              |
//+------------------------------------------------------------------+

double IsSwingHigh(int barIndex, const double &high[], const double &low[])
{
   if(barIndex < MinBarsForStructure || barIndex + MinBarsForStructure >= ArraySize(high))
      return 0;
   
   bool isHigh = true;
   for(int i = 1; i <= MinBarsForStructure; i++)
   {
      if(high[barIndex] < high[barIndex + i] || high[barIndex] < high[barIndex - i])
      {
         isHigh = false;
         break;
      }
   }
   return isHigh ? high[barIndex] : 0;
}

double IsSwingLow(int barIndex, const double &high[], const double &low[])
{
   if(barIndex < MinBarsForStructure || barIndex + MinBarsForStructure >= ArraySize(low))
      return 0;
   
   bool isLow = true;
   for(int i = 1; i <= MinBarsForStructure; i++)
   {
      if(low[barIndex] > low[barIndex + i] || low[barIndex] > low[barIndex - i])
      {
         isLow = false;
         break;
      }
   }
   return isLow ? low[barIndex] : 0;
}

bool CheckLiquiditySweep(int barIndex, const double &high[], const double &low[], 
                         PriceLevel swingPoint, bool bullish)
{
   if(swingPoint.barIndex < 0)
      return false;
   
   if(bullish)
   {
      // Bullish sweep: price goes below swing low then recovers
      double sweepLevel = swingPoint.price - (swingPoint.price * LiquiditySweepPercent / 100.0);
      for(int i = swingPoint.barIndex; i < barIndex; i++)
      {
         if(low[i] <= sweepLevel)
            return true;
      }
   }
   else
   {
      // Bearish sweep: price goes above swing high then reverses
      double sweepLevel = swingPoint.price + (swingPoint.price * LiquiditySweepPercent / 100.0);
      for(int i = swingPoint.barIndex; i < barIndex; i++)
      {
         if(high[i] >= sweepLevel)
            return true;
      }
   }
   return false;
}

bool DetectBOSCHoCH(int barIndex, const double &high[], const double &low[], const double &close[])
{
   if(barIndex < 20)
      return false;
   
   // Break of Structure: price closes beyond previous swing
   bool bosHigh = (close[barIndex] > high[barIndex - 1] && close[barIndex - 1] > high[barIndex - 2]);
   bool bosLow = (close[barIndex] < low[barIndex - 1] && close[barIndex - 1] < low[barIndex - 2]);
   
   return bosHigh || bosLow;
}

bool DetectFVG(int barIndex, const double &high[], const double &low[])
{
   if(barIndex < 2)
      return false;
   
   // Fair Value Gap: gap between candles
   double gap1 = (high[barIndex - 1] - low[barIndex]) / Point();
   double gap2 = (high[barIndex] - low[barIndex - 2]) / Point();
   
   return (gap1 >= FVG_Minimum_Pips || gap2 >= FVG_Minimum_Pips);
}

bool DetectOrderBlock(int barIndex, const double &high[], const double &low[], 
                      const double &close[], const double &open[])
{
   if(barIndex < 3)
      return false;
   
   // Order Block: strong rejection candle with size
   double bodySize = MathAbs(close[barIndex] - open[barIndex]);
   double candle_high_low = high[barIndex] - low[barIndex];
   double bodyRatio = candle_high_low > 0 ? bodySize / candle_high_low : 0;
   
   // Strong directional candle with visible structure
   double atr = iATR(Symbol(), PERIOD_M5, ATR_Period, barIndex);
   return bodyRatio > 0.6 && candle_high_low > atr * 1.5;
}

bool CheckRSI(int barIndex)
{
   int rsiVal = iRSI(Symbol(), PERIOD_M5, RSI_Period, barIndex);
   return (rsiVal > 30 && rsiVal < 70); // Neutral zone = setup potential
}

bool CheckMACD(int barIndex)
{
   double macd, signal;
   GetMACD(barIndex, macd, signal);
   return (macd > signal); // Bullish alignment
}

bool CheckEMAAlignment(int barIndex)
{
   double ema20 = iMA(Symbol(), PERIOD_M5, EMA_20_Period, 0, MODE_EMA, PRICE_CLOSE, barIndex);
   double ema50 = iMA(Symbol(), PERIOD_M5, EMA_50_Period, 0, MODE_EMA, PRICE_CLOSE, barIndex);
   return (ema20 > ema50); // Bullish alignment
}

void GetMACD(int barIndex, double &macd, double &signal)
{
   int handle = iMACD(Symbol(), PERIOD_M5, MACD_Fast, MACD_Slow, MACD_Signal, PRICE_CLOSE);
   
   double macdBuffer[];
   double signalBuffer[];
   
   CopyBuffer(handle, 0, barIndex, 1, macdBuffer);
   CopyBuffer(handle, 1, barIndex, 1, signalBuffer);
   
   macd = (ArraySize(macdBuffer) > 0) ? macdBuffer[0] : 0;
   signal = (ArraySize(signalBuffer) > 0) ? signalBuffer[0] : 0;
}

//+------------------------------------------------------------------+
//| SETUP MANAGEMENT                                                 |
//+------------------------------------------------------------------+

void AddSetup(Setup &setup)
{
   if(setupCount >= MaximumDisplayedSetups)
   {
      // Shift old setups
      for(int i = 0; i < MaximumDisplayedSetups - 1; i++)
      {
         activeSetups[i] = activeSetups[i + 1];
      }
      setupCount--;
   }
   activeSetups[setupCount - 1] = setup;
}

void UpdateSetups(int rates_total, const double &close[])
{
   for(int i = 0; i < setupCount; i++)
   {
      if(activeSetups[i].setupState == "ACTIVE" || activeSetups[i].setupState == "ARMED")
      {
         double currentPrice = close[0];
         
         if(activeSetups[i].isBullish)
         {
            if(currentPrice >= activeSetups[i].tp2)
            {
               activeSetups[i].setupState = "TP";
               activeSetups[i].outcomeState = "WON";
               activeSetups[i].outcome = (activeSetups[i].tp2 - activeSetups[i].entryLevel) / Point();
               RecordSetupOutcome(activeSetups[i]);
            }
            else if(currentPrice <= activeSetups[i].stopLoss)
            {
               activeSetups[i].setupState = "SL";
               activeSetups[i].outcomeState = "LOSS";
               activeSetups[i].outcome = (activeSetups[i].stopLoss - activeSetups[i].entryLevel) / Point();
               RecordSetupOutcome(activeSetups[i]);
            }
            else if(currentPrice >= activeSetups[i].tp1)
            {
               activeSetups[i].setupState = "TP";
            }
         }
         else
         {
            if(currentPrice <= activeSetups[i].tp2)
            {
               activeSetups[i].setupState = "TP";
               activeSetups[i].outcomeState = "WON";
               activeSetups[i].outcome = (activeSetups[i].entryLevel - activeSetups[i].tp2) / Point();
               RecordSetupOutcome(activeSetups[i]);
            }
            else if(currentPrice >= activeSetups[i].stopLoss)
            {
               activeSetups[i].setupState = "SL";
               activeSetups[i].outcomeState = "LOSS";
               activeSetups[i].outcome = (activeSetups[i].entryLevel - activeSetups[i].stopLoss) / Point();
               RecordSetupOutcome(activeSetups[i]);
            }
            else if(currentPrice <= activeSetups[i].tp1)
            {
               activeSetups[i].setupState = "TP";
            }
         }
         
         // Check expiration (24 hours from setup creation)
         if(TimeCurrent() - activeSetups[i].createdTime > 86400)
         {
            activeSetups[i].setupState = "EXPIRED";
         }
      }
   }
}

void RecordSetupOutcome(Setup &setup)
{
   // Store in recent completed setups
   recentCompletedSetups[recentSetupIndex] = setup;
   recentSetupIndex = (recentSetupIndex + 1) % RecentSetupCount;
   
   // Write to CSV if enabled
   if(EnableCSVJournal)
   {
      int fileHandle = FileOpen(CSVFilePath, FILE_READ | FILE_WRITE | FILE_CSV);
      if(fileHandle != INVALID_HANDLE)
      {
         FileSeek(fileHandle, 0, SEEK_END);
         FileWrite(fileHandle, 
                  TimeToString(setup.createdTime),
                  setup.setupType,
                  setup.isBullish ? "BULLISH" : "BEARISH",
                  DoubleToString(setup.entryLevel, _Digits),
                  DoubleToString(setup.stopLoss, _Digits),
                  DoubleToString(setup.tp1, _Digits),
                  DoubleToString(setup.tp2, _Digits),
                  setup.setupState,
                  setup.outcomeState,
                  DoubleToString(setup.riskReward, 2));
         FileClose(fileHandle);
      }
   }
}

//+------------------------------------------------------------------+
//| DISPLAY FUNCTIONS                                                |
//+------------------------------------------------------------------+

void DisplaySetups(int rates_total, const double &high[], const double &low[], const double &close[])
{
   int yOffset = 30;
   
   // Display active setups
   for(int i = 0; i < setupCount; i++)
   {
      Setup setup = activeSetups[i];
      
      // Draw setup zones
      color zoneColor = setup.isBullish ? BullishSetupColor : BearishSetupColor;
      
      // Entry zone
      DrawHorizontalLine("Entry_" + IntToString(setup.setupID), setup.entryLevel, zoneColor, 2);
      
      // Stop Loss
      DrawHorizontalLine("SL_" + IntToString(setup.setupID), setup.stopLoss, clrRed, 1);
      
      // TP levels
      DrawHorizontalLine("TP1_" + IntToString(setup.setupID), setup.tp1, clrGreen, 1);
      DrawHorizontalLine("TP2_" + IntToString(setup.setupID), setup.tp2, clrDarkGreen, 2);
      
      // Display label
      string label = (setup.isBullish ? "↑ " : "↓ ") + 
                    setup.setupType + " | " + 
                    setup.setupState + " | R:R " + 
                    DoubleToString(setup.riskReward, 2);
      
      DrawLabel("Label_" + IntToString(setup.setupID), 20, yOffset, label, zoneColor, LabelFontSize);
      yOffset += 20;
   }
   
   // Display recent completed setups
   int recentY = 200;
   DrawLabel("RecentLabel", 20, recentY, "RECENT SETUPS:", clrWhite, 11);
   recentY += 20;
   
   for(int i = 0; i < RecentSetupCount; i++)
   {
      if(recentCompletedSetups[i].setupID > 0)
      {
         Setup setup = recentCompletedSetups[i];
         color outcomeColor = (setup.outcomeState == "WON") ? clrGreen : clrRed;
         
         string recentLabel = setup.setupType + " | " + 
                             (setup.isBullish ? "BULL" : "BEAR") + " | " + 
                             setup.outcomeState + " | " + 
                             DoubleToString(setup.outcome, 1) + " pips";
         
         DrawLabel("Recent_" + IntToString(i), 20, recentY, recentLabel, outcomeColor, 9);
         recentY += 18;
      }
   }
}

void DisplayMarketStructure(int rates_total, const double &high[], const double &low[], const double &close[])
{
   // Determine current market structure
   if(close[0] > close[1] && close[1] > close[2])
      currentMarketStructure = "BULLISH";
   else if(close[0] < close[1] && close[1] < close[2])
      currentMarketStructure = "BEARISH";
   else
      currentMarketStructure = "SIDEWAYS";
   
   // Determine bias
   double ema20 = iMA(Symbol(), PERIOD_M5, EMA_20_Period, 0, MODE_EMA, PRICE_CLOSE, 0);
   double ema50 = iMA(Symbol(), PERIOD_M5, EMA_50_Period, 0, MODE_EMA, PRICE_CLOSE, 0);
   currentBias = (ema20 > ema50) ? "BULLISH BIAS" : "BEARISH BIAS";
   
   // Display info
   int infoY = 30;
   DrawLabel("Structure", 200, infoY, "Market Structure: " + currentMarketStructure, clrCyan, 11);
   DrawLabel("Bias", 200, infoY + 20, "Structural Bias: " + currentBias, clrCyan, 11);
   DrawLabel("SignalCount", 200, infoY + 40, "Daily Signals: " + IntToString(dailySignalCount) + "/" + IntToString(MinimumDailySignals), clrYellow, 11);
   DrawLabel("ScannedBars", 200, infoY + 60, "Scanned Bars: " + IntToString(totalScannedBars), clrGray, 10);
}

void DrawHorizontalLine(string name, double price, color lineColor, int thickness)
{
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_HLINE, 0, TimeCurrent(), price);
   }
   else
   {
      ObjectSetDouble(0, name, OBJPROP_PRICE, price);
   }
   
   ObjectSetInteger(0, name, OBJPROP_COLOR, lineColor);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, thickness);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
}

void DrawLabel(string name, int x, int y, string text, color textColor, int fontSize)
{
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   }
   
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, textColor);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
}

//+------------------------------------------------------------------+
//| ALERT FUNCTIONS                                                  |
//+------------------------------------------------------------------+

void SendAlert(string message)
{
   if(EnableAlerts)
      Alert(message);
   
   if(EnablePushNotifications)
      SendNotification(message);
   
   if(EnableEmailAlerts)
      SendMail("IronHawk SMC Alert", message);
   
   Print(message);
}

//+------------------------------------------------------------------+
//| END OF INDICATOR                                                 |
//+------------------------------------------------------------------+
