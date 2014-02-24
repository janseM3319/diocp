unit uMyObjectPool;

interface

uses
  SyncObjs, Classes, Windows, SysUtils;

type
  TObjectBlock = record
  private
    FObject:TObject;
    FUsing:Boolean;
    FBorrowTime:Cardinal;   //借出时间
    FRelaseTime:Cardinal;   //归还时间
  end;

  PObjectBlock = ^TObjectBlock;

  TMyObjectPool = class(TObject)
  private
    FLocker: TCriticalSection;

    //全部归还信号
    FReleaseSingle: THandle;

    //有可用的对象信号灯
    FUsableSingle: THandle;

    FMaxNum: Integer;
    FObjectList: TList;

    FBusyList:TList;
    FName: String;
    FTimeOut: Integer;
    FUsableList:TList;

    procedure makeSingle;
    function GetCount: Integer;
    procedure lock;
    procedure unLock;
  protected
    function createObject: TObject; virtual;
    procedure clear;
  public
    constructor Create;
    destructor Destroy; override;

    /// <summary>
    ///  借用一个对象
    /// </summary>
    function borrowObject: TObject;


    /// <summary>
    ///   归还一个对象
    /// </summary>
    procedure releaseObject(pvObject:TObject);

    /// <summary>
    ///  获取正在使用的个数
    /// </summary>
    function getBusyCount:Integer;



    //等待全部还回
    function waitForReleaseSingle: Boolean;

    /// <summary>
    ///   等待全部归还信号灯
    /// </summary>
    procedure checkWaitForUsableSingle;

    /// <summary>
    ///  当前总的个数
    /// </summary>
    property Count: Integer read GetCount;

    /// <summary>
    ///  最大对象个数
    /// </summary>
    property MaxNum: Integer read FMaxNum write FMaxNum;



    /// <summary>
    ///  对象池名称
    /// </summary>
    property Name: String read FName write FName;

    /// <summary>
    ///   等待超时信号灯
    ///   单位毫秒
    /// </summary>
    property TimeOut: Integer read FTimeOut write FTimeOut;
  end;

implementation

procedure TMyObjectPool.clear;
var
  lvObj:PObjectBlock;
begin
  lock;
  try
    while FUsableList.Count > 0 do
    begin
      lvObj := PObjectBlock(FUsableList[FObjectList.Count-1]);
      lvObj.FObject.Free;
      FreeMem(lvObj, SizeOf(TObjectBlock));
      FUsableList.Delete(FObjectList.Count-1);
    end; 
  finally
    unLock;
  end;
end;

constructor TMyObjectPool.Create;
begin
  inherited Create;
  FLocker := TCriticalSection.Create();
  FBusyList := TList.Create;
  FUsableList := TList.Create;

  //默认可以使用5个
  FMaxNum := 5;

  //等待超时信号灯 5 秒
  FTimeOut := 5 * 1000;

  //
  FUsableSingle := CreateEvent(nil, True, True, nil);

  //创建信号灯,手动控制
  FReleaseSingle := CreateEvent(nil, True, True, nil);

  makeSingle;  
end;

function TMyObjectPool.createObject: TObject;
begin
  Result := nil;  
end;

destructor TMyObjectPool.Destroy;
begin
  waitForReleaseSingle;  
  clear;
  FLocker.Free;
  FBusyList.Free;
  FUsableList.Free;
  inherited Destroy;
end;

function TMyObjectPool.getBusyCount: Integer;
begin
  Result := FBusyList.Count;
end;

{ TMyObjectPool }

procedure TMyObjectPool.releaseObject(pvObject:TObject);
var
  i:Integer;
  lvObj:PObjectBlock;
begin
  lock;
  try
    for i := 0 to FBusyList.Count - 1 do
    begin
      lvObj := PObjectBlock(FBusyList[i]);
      if lvObj.FObject = pvObject then
      begin
        FUsableList.Add(lvObj);
        lvObj.FRelaseTime := GetTickCount;
        FBusyList.Delete(i);
        Break;
      end;
    end;             

    makeSingle;
  finally
    unLock;
  end;
end;

procedure TMyObjectPool.unLock;
begin
  FLocker.Leave;
end;

function TMyObjectPool.borrowObject: TObject;
var
  i:Integer;
  lvObj:PObjectBlock;
  lvObject:TObject;
begin
  Result := nil;
  
  //是否有可用的对象
  checkWaitForUsableSingle;
  
  lock;
  try
    lvObject := nil;
    if FUsableList.Count > 0 then
    begin
      lvObj := PObjectBlock(FUsableList[FUsableList.Count-1]);
      FUsableList.Delete(FUsableList.Count-1);
      FBusyList.Add(lvObj);
      lvObj.FBorrowTime := getTickCount;
      lvObj.FRelaseTime := 0;
      lvObject := lvObj.FObject;
    end else
    begin
      if GetCount >= FMaxNum then raise exception.CreateFmt('超出对象池[%s]允许的范围[%d]', [self.ClassName, FMaxNum]);
      lvObject := createObject;
      if lvObject = nil then raise exception.CreateFmt('不能得到对象,对象池[%s]未继承处理createObject函数', [self.ClassName]);

      GetMem(lvObj, SizeOf(TObjectBlock));
      try
        ZeroMemory(lvObj, SizeOf(TObjectBlock));
        
        lvObj.FObject := lvObject;
        lvObj.FBorrowTime := GetTickCount;
        lvObj.FRelaseTime := 0;
        FBusyList.Add(lvObj);
      except
        lvObject.Free;
        FreeMem(lvObj, SizeOf(TObjectBlock));
        raise;
      end;
    end;

    //设置信号灯
    makeSingle;

    Result := lvObject;
  finally
    unLock;
  end;       
end;

procedure TMyObjectPool.makeSingle;
begin
  if (GetCount < FMaxNum)      //还可以创建
     or (FUsableList.Count > 0)  //还有可使用的
     then
  begin
    //设置有信号
    SetEvent(FUsableSingle);
  end else
  begin
    //没有信号
    ResetEvent(FUsableSingle);
  end;

  if FUsableList.Count > 0 then
  begin
    //没有信号
    ResetEvent(FReleaseSingle);
  end else
  begin
    //全部归还有信号
    SetEvent(FReleaseSingle)
  end;
end;

function TMyObjectPool.GetCount: Integer;
begin
  Result := FUsableList.Count + FBusyList.Count;
end;

procedure TMyObjectPool.lock;
begin
  FLocker.Enter;
end;

function TMyObjectPool.waitForReleaseSingle: Boolean;
var
  lvRet:DWORD;
begin
  Result := false;
  lvRet := WaitForSingleObject(FReleaseSingle, INFINITE);
  if lvRet = WAIT_OBJECT_0 then
  begin
    Result := true;
  end;
end;

procedure TMyObjectPool.checkWaitForUsableSingle;
var
  lvRet:DWORD;
begin
  lvRet := WaitForSingleObject(FReleaseSingle, FTimeOut);
  if lvRet <> WAIT_OBJECT_0 then
  begin
    raise Exception.CreateFmt('对象池[%s]等待可使用对象超时,使用状态[%d/%d]!',
      [FName, getBusyCount, FMaxNum]);
  end;                                                                 
end;

end.
