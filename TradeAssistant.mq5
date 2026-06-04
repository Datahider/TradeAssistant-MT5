//+------------------------------------------------------------------+
//|                                      RandomDealATRButtonsAuto.mq5|
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>

CTrade trade;

//--- Inputs
input double RiskMoney          = 1000.0;
input int    ATRPeriod          = 14;
input double ATRMultiplier      = 2.0;
input int    CloseAfterBars     = 24;
input bool   OnePositionOnly    = true;
input bool   UseATRTrailing     = true;

//--- Buttons
string BtnSell = "Sell";
string BtnDeal = "Deal";
string BtnBuy  = "Buy";

//--- Service
datetime lastBarTime = 0;


//+------------------------------------------------------------------+
void Log(string msg)
{
   Print("[RandomDealATR] ", msg);
}


//+------------------------------------------------------------------+
int OnInit()
{
   //MathSrand(RandomSeed);

   CreateButtons();

   lastBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);

   Log("EA started on " + _Symbol);

   if(PositionSelect(_Symbol))
   {
      ENUM_POSITION_TYPE type =
         (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      datetime openTime =
         (datetime)PositionGetInteger(POSITION_TIME);

      int barsPassed =
         iBarShift(_Symbol, PERIOD_CURRENT, openTime);

      double sl =
         PositionGetDouble(POSITION_SL);

      Log(
         "Found existing position: "
         + EnumToString(type)
         + ", bars passed="
         + IntegerToString(barsPassed)
         + ", SL="
         + DoubleToString(sl,_Digits)
      );
   }
   else
   {
      Log("No open position found");
   }

   return(INIT_SUCCEEDED);
}


//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   ObjectDelete(0, BtnSell);
   ObjectDelete(0, BtnDeal);
   ObjectDelete(0, BtnBuy);

   Log("EA stopped");
}


//+------------------------------------------------------------------+
void OnTick()
{
   if(IsNewBar())
   {
      Log("New bar");

      if(UseATRTrailing)
         TrailPositionByATR();

      CheckPositionCloseByBars();
   }
}


//+------------------------------------------------------------------+
void OnChartEvent(
   const int id,
   const long &lparam,
   const double &dparam,
   const string &sparam)
{
   if(id != CHARTEVENT_OBJECT_CLICK)
      return;

   if(sparam == BtnBuy)
      OpenTrade(ORDER_TYPE_BUY, "Button Buy");

   if(sparam == BtnSell)
      OpenTrade(ORDER_TYPE_SELL, "Button Sell");

   if(sparam == BtnDeal)
      OpenRandomTrade("Button Deal");
}


//+------------------------------------------------------------------+
void CreateButtons()
{
   CreateButton(BtnSell, 20, 20);
   CreateButton(BtnDeal, 140, 20);
   CreateButton(BtnBuy,  260, 20);
}


//+------------------------------------------------------------------+
void CreateButton(string name,int x,int y)
{
   ObjectCreate(0,name,OBJ_BUTTON,0,0,0);

   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);

   ObjectSetInteger(0,name,OBJPROP_XSIZE,110);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,35);

   ObjectSetString(0,name,OBJPROP_TEXT,name);
}


//+------------------------------------------------------------------+
void OpenRandomTrade(string reason)
{
   ENUM_ORDER_TYPE type =
      (MathRand() % 2 == 0)
      ? ORDER_TYPE_BUY
      : ORDER_TYPE_SELL;

   OpenTrade(type, reason);
}


//+------------------------------------------------------------------+
void OpenTrade(ENUM_ORDER_TYPE type, string reason)
{
   if(OnePositionOnly && PositionSelect(_Symbol))
   {
      Log("Trade skipped: position already exists");
      return;
   }

   double atr = GetATR();

   if(atr <= 0)
   {
      Log("Trade skipped: ATR unavailable");
      return;
   }

   double stopDistance = atr * ATRMultiplier;

   double ask = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol,SYMBOL_BID);

   double sl = 0;

   if(type == ORDER_TYPE_BUY)
      sl = ask - stopDistance;

   if(type == ORDER_TYPE_SELL)
      sl = bid + stopDistance;

   double lot = CalculateLot(stopDistance);

   if(lot <= 0)
      return;

   bool result = false;

   if(type == ORDER_TYPE_BUY)
      result = trade.Buy(
         lot,_Symbol,ask,sl,0,"ATR Buy"
      );

   if(type == ORDER_TYPE_SELL)
      result = trade.Sell(
         lot,_Symbol,bid,sl,0,"ATR Sell"
      );

   if(result)
   {
      Log(
         "Opened "
         + EnumToString(type)
         + " reason="
         + reason
         + " lot="
         + DoubleToString(lot,2)
         + " ATR="
         + DoubleToString(atr,_Digits)
         + " SL="
         + DoubleToString(sl,_Digits)
      );
   }
   else
   {
      Log(
         "Open failed. Retcode="
         + IntegerToString(trade.ResultRetcode())
      );
   }
}


//+------------------------------------------------------------------+
//| ATR from previous closed bar                                     |
//+------------------------------------------------------------------+
double GetATR()
{
   return GetATRByShift(1);
}


//+------------------------------------------------------------------+
double GetATRByShift(int shift)
{
   int handle =
      iATR(_Symbol, PERIOD_CURRENT, ATRPeriod);

   if(handle == INVALID_HANDLE)
      return 0;

   double buffer[];

   if(CopyBuffer(handle,0,shift,1,buffer) <= 0)
   {
      IndicatorRelease(handle);
      return 0;
   }

   IndicatorRelease(handle);

   return buffer[0];
}


//+------------------------------------------------------------------+
double CalculateLot(double stopDistance)
{
   double tickSize =
      SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);

   double tickValue =
      SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);

   if(tickSize <= 0 || tickValue <= 0)
      return 0;

   double riskPerLot =
      (stopDistance / tickSize) * tickValue;

   if(riskPerLot <= 0)
      return 0;

   double lot = RiskMoney / riskPerLot;

   double minLot =
      SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);

   double maxLot =
      SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);

   double stepLot =
      SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);

   if(lot < minLot)
   {
      Log("Trade skipped: minimal lot exceeds risk");
      return 0;
   }

   lot = MathFloor(lot / stepLot) * stepLot;
   lot = NormalizeDouble(lot,2);

   if(lot > maxLot)
      lot = maxLot;

   return lot;
}


//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime currentBar =
      iTime(_Symbol, PERIOD_CURRENT, 0);

   if(currentBar != lastBarTime)
   {
      lastBarTime = currentBar;
      return true;
   }

   return false;
}


//+------------------------------------------------------------------+
void TrailPositionByATR()
{
   if(!PositionSelect(_Symbol))
      return;

   double atr = GetATR();

   if(atr <= 0)
      return;

   double stopDistance =
      atr * ATRMultiplier;

   ENUM_POSITION_TYPE type =
      (ENUM_POSITION_TYPE)
      PositionGetInteger(POSITION_TYPE);

   double currentSL =
      PositionGetDouble(POSITION_SL);

   double currentTP =
      PositionGetDouble(POSITION_TP);

   double bid =
      SymbolInfoDouble(_Symbol,SYMBOL_BID);

   double ask =
      SymbolInfoDouble(_Symbol,SYMBOL_ASK);

   double newSL = 0;

   if(type == POSITION_TYPE_BUY)
   {
      newSL = bid - stopDistance;

      if(currentSL == 0 || newSL > currentSL)
      {
         Log(
            "Trailing BUY SL "
            + DoubleToString(currentSL,_Digits)
            + " -> "
            + DoubleToString(newSL,_Digits)
         );

         trade.PositionModify(
            _Symbol,newSL,currentTP
         );
      }
      else
      {
         Log("Trailing skipped BUY");
      }
   }

   if(type == POSITION_TYPE_SELL)
   {
      newSL = ask + stopDistance;

      if(currentSL == 0 || newSL < currentSL)
      {
         Log(
            "Trailing SELL SL "
            + DoubleToString(currentSL,_Digits)
            + " -> "
            + DoubleToString(newSL,_Digits)
         );

         trade.PositionModify(
            _Symbol,newSL,currentTP
         );
      }
      else
      {
         Log("Trailing skipped SELL");
      }
   }
}


//+------------------------------------------------------------------+
void CheckPositionCloseByBars()
{
   if(!PositionSelect(_Symbol))
      return;

   datetime openTime =
      (datetime)
      PositionGetInteger(POSITION_TIME);

   int barsPassed =
      iBarShift(
         _Symbol,
         PERIOD_CURRENT,
         openTime
      );

   Log(
      "Position age: "
      + IntegerToString(barsPassed)
      + "/"
      + IntegerToString(CloseAfterBars)
      + " bars"
   );

   if(barsPassed >= CloseAfterBars)
   {
      Log("Closing by bars limit");
      trade.PositionClose(_Symbol);
   }
}
//+------------------------------------------------------------------+
