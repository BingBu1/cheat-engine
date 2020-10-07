--dotnetinfo is a passive .net query tool, but it can go to a active state if needed

if getTranslationFolder()~='' then
  loadPOFile(getTranslationFolder()..'dotnetinfo.po')
end

if getOperatingSystem()==0 then
  pathsep=[[\]]
else
  pathsep='/'
end

local DPIMultiplier=(getScreenDPI()/96)
local CONTROL_MONO=0
local CONTROL_DOTNET=1

--[[local]] DataSource={} --All collected data about the current process. From domains, to images, to classes, to fields and methods. Saves on queries and multiple windows can use it
local CurrentProcess

local frmDotNetInfos={} --keep track of the windows


local function CTypeToString(ctype)
  local r=monoTypeToCStringLookup[ctype]
  if r==nil then
    r='Object '
  end
  
  return r
end

local function getClassInstances(Class, ProgressBar)  
  if Class.Image.Domain.Control==CONTROL_MONO then
    --get the vtable and then scan for objects with this
    return mono_class_findInstancesOfClassListOnly(nil, Class.Handle)    
  else
    return DataSource.DotNetDataCollector.enumAllObjectsOfType(Class.Image.Handle, Class.Handle)    
  end  
end

local function getClassParent(Class)
  if Class.Parent==nil then
    --is a class definition with an image entry, but unlinked from the actual class and image list
    Class.Parent={}
   

    if Class.ParentToken then      
      if Class.Image.Domain.Control==CONTROL_MONO then
        --mono    
        
        Class.Parent.Handle=Class.ParentToken
        Class.Parent.Name=mono_class_getName(Class.ParentToken)
        Class.Parent.NameSpace=mono_class_getNamespace(Class.ParentToken)
        Class.Parent.ParentToken=mono_class_getParent(Class.ParentToken)
                
        local ImageHandle=mono_class_getImage(Class.ParentToken)
        Class.Parent.Image=Class.Image.Domain.Images.HandleLookup[ImageHandle]
      else
        --dotnet  
        Class.Parent.Handle=Class.ParentToken.TypedefToken
        local classdata=DataSource.DotNetDataCollector.GetTypeDefData(Class.ParentToken.ModuleHandle, Class.ParentToken.TypedefToken) --probably overkill. Perhaps just a getclassname ot something in the future
        if classdata then
          Class.Parent.Name=classdata.ClassName
          Class.Parent.NameSpace=''
          Class.Parent.ParentToken=DataSource.DotNetDataCollector.GetTypeDefParent(Class.ParentToken.ModuleHandle, Class.ParentToken.TypedefToken)
          
          local ImageHandle=Class.ParentToken.ModuleHandle
          Class.Parent.Image=Class.Image.Domain.Images.HandleLookup[ImageHandle] 
        else
          Class.Parent=nil --.Name=''
          
        end        
      end
    else
      Class.Parent=nil
    end
  
  end
  
  return Class.Parent
end

local function getClassMethods(Class)
  Class.Methods={}
  
  local i
  if Class.Image.Domain.Control==CONTROL_MONO then
    local methods=mono_class_enumMethods(Class.Handle)
    if methods then
      for i=1,#methods do
        local e={}
        e.Handle=methods[i].method
        e.Name=methods[i].name
        e.Class=Class
        
        e.Parameters=getParameterFromMethod(e.Handle)
       
        table.insert(Class.Methods, e)
      end
    end
  else
    local methods=DataSource.DotNetDataCollector.GetTypeDefMethods(Class.Image.Handle, Class.Handle)
         
    if methods then
      --MethodToken, Name, Attributes, ImplementationFlags, ILCode, NativeCode, SecondaryNativeCode[]: Integer
      for i=1,#methods do
        local e={}
        --_G.Methods=methods
        --_G.Class=Class
        e.Handle=methods[i].MethodToken
        e.Name=methods[i].Name
        e.Class=Class
        e.ILCode=methods[i].ILCode
        e.NativeCode=methods[i].NativeCode
        
        --if e.NativeCode and e.NativeCode~=0 then
        --  print(e.Class.Name..'.'..e.Name..' is compiled at '..string.format('%x', e.NativeCode))
        --end
        
        --print("Method "..e.Name)
        --build parameter list
        local plist=DataSource.DotNetDataCollector.GetMethodParameters(Class.Image.Handle, methods[i].MethodToken)
        if plist then
          --print("Plist is valid.  #plist="..#plist) 
          e.Parameters="("
          for i=1,#plist do
            --print("plist var1 = "..plist[i].CType)
            e.Parameters=e.Parameters..CTypeToString(plist[i].CType).." "..plist[i].Name
            if i<#plist then
              e.Parameters=e.Parameters..', '
            end
          end
          
          e.Parameters=e.Parameters..")"
        else
          --print("plist failed")
          e.Parameters='(...)'        
        end
      
        table.insert(Class.Methods, e)
      end
    end
  end
end

local function getClassFields(Class)
  local r={}
  
  local i
  if Class.Image.Domain.Control==CONTROL_MONO then
    local fields=mono_class_enumFields(Class.Handle, true)
    for i=1,#fields do
      local e={}
      e.Handle=fields[i].type
      e.Name=fields[i].name
      e.VarType=fields[i].monotype
      e.VarTypeName=fields[i].typename
      e.Offset=fields[i].offset
      e.Static=fields[i].isStatic
      e.Const=fields[i].isConst
      
      e.Class=Class
      
      table.insert(r,e)
    end
   
  else
    --mono
    local classdata=DataSource.DotNetDataCollector.GetTypeDefData(Class.Image.Handle, Class.Handle)
    if classdata and classdata.Fields then
      for i=1,#classdata.Fields do
        --Offset, FieldType, Name
        local e={}
        e.Handle=classdata.Fields[i].Token
        e.Name=classdata.Fields[i].Name
        e.VarType=classdata.Fields[i].FieldType
        e.VarTypeName=classdata.Fields[i].FieldTypeClassName
        e.Offset=classdata.Fields[i].Offset
        e.Static=classdata.Fields[i].IsStatic
        e.Class=Class
        
        
        table.insert(r,e)
      end
    end    
  end
  
  table.sort(r, function(e1,e2) return e1.Offset < e2.Offset end)
 
  Class.Fields=r
  return r
end

local function getClasses(Image)
  if Image.Classes==nil then
    print("getClasses Error: Image.Classes was not initialized")
    return
  end
  
  if (not Image.Classes.Busy) then
    print("getClasses Error: Image.Classes was not busy")
    return
  end 

  --get the classlist
  local i
  if (Image.Domain.Control==CONTROL_MONO) then
    local classlist=mono_image_enumClasses(Image.Handle)        
    if classlist then         
      for i=1,#classlist do
        local e={}        
        e.Name=classlist[i].classname
        e.NameSpace=classlist[i].namespace        
        e.Handle=classlist[i].class
        e.ParentToken=mono_class_getParent(e.Handle)         
        e.Image=Image
        
        table.insert(Image.Classes,e)
      end     
    end
  else
    local classlist=DataSource.DotNetDataCollector.EnumTypeDefs(Image.Handle)  
    for i=1,#classlist do
     --TypeDefToken, Name, Flags, Extends
      local e={}
      e.Name=classlist[i].Name
      e.NameSpace='' --nyi
      e.Handle=classlist[i].TypeDefToken
      e.ParentToken=DataSource.DotNetDataCollector.GetTypeDefParent(Image.Handle, e.Handle) --classlist[i].Extends
      e.Image=Image
      
      table.insert(Image.Classes,e)
    end
  end

  table.sort(Image.Classes, function(e1,e2) return e1.Name < e2.Name end)
  
  return Image.Classes  
end

local function getImages(Domain)
  local i
  
  Domain.Images={}
  --create a HandleToImage lookup table  
  Domain.Images.HandleLookup={}
  
  if Domain.Control==CONTROL_MONO then
    --mono
    local a=mono_enumAssemblies(Domain.DomainHandle)
    for i=1,#a do
      local image=mono_getImageFromAssembly(a[i])
      local e={}
      e.Handle=image
      e.Name=mono_image_get_name(image) --full path
      e.FileName=extractFileName(e.Name)
      e.Domain=Domain
      table.insert(Domain.Images,e)
      
      Domain.Images.HandleLookup[e.Handle]=e
    end
  else
    --dotnet
    local modules=DataSource.DotNetDataCollector.EnumModuleList(Domain.Handle)  
    --ModuleHandle, BaseAddress, Name
    for i=1,#modules do
      local e={}
      e.Handle=modules[i].ModuleHandle
      e.Name=modules[i].Name --full path
      e.FileName=extractFileName(e.Name)
      e.BaseAddress=modules[i].BaseAddress
      e.Domain=Domain
      
      table.insert(Domain.Images,e)
      Domain.Images.HandleLookup[e.Handle]=e
      
    end
  end
  
  --sort the list
  table.sort(Domain.Images, function(e1,e2) return e1.FileName < e2.FileName end)
  

  
end

local function getDomains()  
  DataSource.Domains={}
  
  if monopipe then
    local mr=mono_enumDomains()  
    local i
    for i=1,#mr do
      local e={}
      e.Handle=mr[i]
      e.Control=CONTROL_MONO
      table.insert(DataSource.Domains,e)
    end
  end
  
  local mr=DataSource.DotNetDataCollector.EnumDomains()  
  for i=1,#mr do
    local e={}
    e.Handle=mr[i].DomainHandle
    e.Name=mr[i].Name
    e.Control=CONTROL_DOTNET
    table.insert(DataSource.Domains,e)
  end  
  
  return DataSource.Domains
end

local function clearClassInformation(frmDotNetInfo)
  frmDotNetInfo.lvStaticFields.Items.clear()
  frmDotNetInfo.lvFields.Items.clear()
  frmDotNetInfo.lvMethods.Items.clear()
  frmDotNetInfo.gbClassInformation.Caption='Class Information'
  frmDotNetInfo.CurrentlyDisplayedClass=nil
end

local function ClassFetchWaitTillReadyAndSendData(thread, frmDotNetInfo, Image, OnDataFunction, FetchDoneFunction)
  --print("ClassFetchWaitTillReadyAndSendData")
  if Image.Classes==nil then 
    print("ClassFetchWaitTillReadyAndSendData Error: Image.Classes is nil")
    return
  end
  
  while Image.Classes.Busy and (not thread.Terminated) do 
    sleep(100)    
  end
  
 -- print("after wait")
  if thread.Terminated or Image.Classes.Busy then return end
  
  local i
  local block={}
  for i=1,#Image.Classes do
    local j=1+((i-1) % 10)
    block[j]=Image.Classes[i]
    
    if j==10 then
      synchronize(OnDataFunction,thread, block)
      block={}      
    end
  end
  
  if #block>0 then
    synchronize(OnDataFunction,thread, block)
  end
  
  synchronize(FetchDoneFunction)  
end

local function StartClassFetch(frmDotNetInfo, Image, OnDataFunction, FetchDoneFunction)
  --create a thread that fetches the full classlist if needed and then calls the OnDataFunction untill full 
  --StartClassFetch called while frmDotNetInfo.ClassFetchThread is not nil. Destroy the old one first  
  if frmDotNetInfo.ClassFetchThread then
    --print("killing old thread")
    frmDotNetInfo.ClassFetchThread.terminate()
    frmDotNetInfo.ClassFetchThread.waitfor()
    frmDotNetInfo.ClassFetchThread.destroy()
    frmDotNetInfo.ClassFetchThread=nil
    
    
  end
  
  if Image.Classes==nil then
    Image.Classes={}
    Image.Classes.Busy=true
    
    --create a thread that fetches the classes
    frmDotNetInfo.ClassFetchThread=createThread(function(t)
      --get the classess
      t.FreeOnTerminate(false)
      getClasses(Image)      
      Image.Classes.Busy=nil
      
      if t.Terminated then
        Image.Classes=nil
        return
      end
      
      --all classes are fetched, send to the waiting form
      ClassFetchWaitTillReadyAndSendData(t, frmDotNetInfo, Image, OnDataFunction, FetchDoneFunction)      
    end)  
  else
    --create a thread that waits until Busy is false/gone and fill the list normally
    --print("Already has list")
    frmDotNetInfo.ClassFetchThread=createThread(function(t)
      t.FreeOnTerminate(false)
      ClassFetchWaitTillReadyAndSendData(t, frmDotNetInfo, Image, OnDataFunction, FetchDoneFunction) 
    end)
  end
  

end

local function CancelClassFetch(frmDotNetInfo)
  --interrupts the current classfetch
  if frmDotNetInfo.ClassFetchThread then
    frmDotNetInfo.ClassFetchThread.terminate()
    frmDotNetInfo.ClassFetchThread.waitfor()
    frmDotNetInfo.ClassFetchThread.destroy()
    frmDotNetInfo.ClassFetchThread=nil
  end
end

local function FillClassInfoFields(frmDotNetInfo, Class)
  if frmDotNetInfo==nil then
    print('FillClassInfoFields: Invalid frmDotNetInfo field')
  end
  
  if Class==nil then
    print('FillClassInfoFields: Invalid Class field')
  end
  
  frmDotNetInfo.lvStaticFields.beginUpdate()
  frmDotNetInfo.lvFields.beginUpdate() 
  frmDotNetInfo.lvMethods.beginUpdate()
  
  clearClassInformation(frmDotNetInfo)
  
  if Class.Fields==nil then
    getClassFields(Class)
  end
  
  if Class.Methods==nil then
    getClassMethods(Class)
  end
  
  if Class.Fields then  
    for i=1,#Class.Fields do
      if Class.Fields[i].Static then
        local li=frmDotNetInfo.lvStaticFields.Items.add()                    
        li.Caption=Class.Fields[i].Name
        
        if Class.Fields[i].VarTypeName and Class.Fields[i].VarTypeName~='' then
          li.SubItems.add(Class.Fields[i].VarTypeName)              
        else
          li.SubItems.add(Class.Fields[i].VarType)    
        end
      else       
        local li=frmDotNetInfo.lvFields.Items.add()
      
        li.Caption=string.format("%.3x", Class.Fields[i].Offset)
        li.Data=i
        li.SubItems.add(Class.Fields[i].Name)
        if Class.Fields[i].VarTypeName and Class.Fields[i].VarTypeName~='' then
          li.SubItems.add(Class.Fields[i].VarTypeName)              
        else
          li.SubItems.add(Class.Fields[i].VarType)    
        end               
      end
    end
  end
  
  if Class.Methods then
    for i=1,#Class.Methods do
      local li=frmDotNetInfo.lvMethods.Items.add()   
      li.Caption=Class.Methods[i].Name
      li.SubItems.add(Class.Methods[i].Parameters)
    end
  end

  frmDotNetInfo.lvStaticFields.endUpdate()
  frmDotNetInfo.lvFields.endUpdate()
  frmDotNetInfo.lvMethods.endUpdate()
  
  frmDotNetInfo.CurrentlyDisplayedClass=Class
  
  if frmDotNetInfo.comboFieldBaseAddress.Text~='' then
    frmDotNetInfo.comboFieldBaseAddress.OnChange(frmDotNetInfo.comboFieldBaseAddress)
  end
  
end

local function ClassSelectionChange(frmDotNetInfo, sender)
  
  if sender.ItemIndex>=0 then
    local Domain=DataSource.Domains[frmDotNetInfo.lbDomains.ItemIndex+1]
    local Image=Domain.Images[frmDotNetInfo.lbImages.ItemIndex+1] 
    
    if Image.Classes==nil then return end
    
    local Class=Image.Classes[frmDotNetInfo.lbClasses.ItemIndex+1]      
    if Class==nil then return end
    
    _G.LastClass=Class --debug
    
    local ClassParent=getClassParent(Class)   
    
    
    frmDotNetInfo.gbClassInformation.Caption='Class Information ('..Class.Name..')'
  
    --erase the old inhgeritcance fields  
    while frmDotNetInfo.gbInheritance.ControlCount>0 do
      frmDotNetInfo.gbInheritance.Control[i].destroy()    
    end  
  
    if ClassParent then
      local ClassList={}
      ClassList[1]={}
      ClassList[1].Class=Class
      
      while ClassParent and ClassParent.Handle~=0 and ClassParent.name~='' do
        local e={}
        e.Class=ClassParent
        table.insert(ClassList,e)
        ClassParent=getClassParent(ClassParent)
      end
      
      local l
      for i=1,#ClassList do 
        l=createLabel(frmDotNetInfo.gbInheritance)        
        l.Caption=ClassList[i].Class.Name
        ClassList[i].Label=l
        
        
        if i==1 then
          l.Font.Style="[fsBold]"               
        else        
          l.Font.Style="[fsUnderline]"
          l.Font.Color=clBlue          
        end
        l.Cursor=crHandPoint
        l.OnMouseDown=function(s)
          --show class state
          --print("Showing state "..ClassList[i].Class.Name)            
          FillClassInfoFields(frmDotNetInfo, ClassList[i].Class)
          local j
          for j=1,#ClassList do
            if j==i then --the currently selected index (this is why I like lua)
              ClassList[j].Label.Font.Color=clWindowText
              ClassList[j].Label.Font.Style="[fsBold]" 
            else
              ClassList[j].Label.Font.Style="[fsUnderline]"
              ClassList[j].Label.Font.Color=clBlue   
            end
          end
          frmDotNetInfo.gbInheritance.OnResize(frmDotNetInfo.gbInheritance, true)
        end
        
        if i~=#ClassList then --not the last item
          l=createLabel(frmDotNetInfo.gbInheritance)          
          l.Caption="->"    
        end
      end    
      
    
      frmDotNetInfo.gbInheritance.Visible=true  
      frmDotNetInfo.gbInheritance.OnResize(frmDotNetInfo.gbInheritance)
      
    else
      frmDotNetInfo.gbInheritance.Visible=false
    end
    
    FillClassInfoFields(frmDotNetInfo, Class)
  
  end  
  
end


local function ImageSelectionChange(frmDotNetInfo, sender)
  frmDotNetInfo.lbClasses.Items.clear()
  clearClassInformation(frmDotNetInfo)
  
  if sender.ItemIndex>=0 then   
    frmDotNetInfo.lbClasses.Enabled=false
    frmDotNetInfo.lbClasses.Cursor=crHourGlass
    
    local Domain=DataSource.Domains[frmDotNetInfo.lbDomains.ItemIndex+1]
    local Image=Domain.Images[frmDotNetInfo.lbImages.ItemIndex+1]
    StartClassFetch(frmDotNetInfo, Image, function(thread, classlistchunk)
      --executed every 10 lines or so, in the main thread
      local i
      if frmDotNetInfo.lbClasses.Enabled==false then
        --there is something to select already
        frmDotNetInfo.lbClasses.Enabled=true
        frmDotNetInfo.lbClasses.Cursor=crDefault      
      end
      
      if thread.Terminated then return end
      
      for i=1,#classlistchunk do
        local fullname
        if classlistchunk[i].NameSpace and classlistchunk[i].NameSpace~='' then
          fullname=classlistchunk[i].NameSpace..'.'..classlistchunk[i].Name
        else          
          fullname=classlistchunk[i].Name
        end
        frmDotNetInfo.lbClasses.Items.add(string.format('%d: (%.8x) - %s', frmDotNetInfo.lbClasses.Items.Count+1, classlistchunk[i].Handle, fullname))
      end
      

    end,
    function()
      --called when done
      frmDotNetInfo.lbClasses.Enabled=true
      frmDotNetInfo.lbClasses.Cursor=crDefault      
    end)
    
    
  end
end


local function DomainSelectionChange(frmDotNetInfo, sender)

  frmDotNetInfo.lbImages.Items.clear()
  frmDotNetInfo.lbClasses.Items.clear()
  clearClassInformation(frmDotNetInfo)

  if sender.ItemIndex>=0 then
    local Domain=DataSource.Domains[sender.ItemIndex+1]
    --get the Images list
    if Domain.Images==nil then
      --fill the images list
      getImages(Domain)   
    end
    
    local i
    local ImageList=Domain.Images
    
    
    for i=1,#ImageList do      
      s=extractFileName(ImageList[i].Name)
      frmDotNetInfo.lbImages.Items.Add(s)
    end
  end
end

local function FindInListBox(listbox)
  _G.lb=lb
  local fd=createFindDialog(frmDotNetInfo)
  fd.Options='[frDown, frHideWholeWord,  frHideEntireScope, frHideUpDown]'
  fd.Title='Search in '..listbox.name

  
    
  fd.OnFind=function()
    local caseSensitive=fd.Options:find('frMatchCase')~=nil
    local start=listbox.ItemIndex
    start=start+1
    
    local needle=fd.FindText
    if not caseSensitive then
      needle=needle:upper()
    end
    
    for i=start, listbox.Items.Count-1 do      
      local haystack=listbox.Items[i]      
      
      if not caseSensitive then
        haystack=haystack:upper()
      end
           
      if haystack:find(needle,0,true)~=nil then
        listbox.itemIndex=i
        return
      end
    end
    beep() 
  end
  
  
  fd.execute()  

  local x,y
  x=(listbox.height / 2)
  x=x-(fd.height/2)
  
  y=(listbox.width / 2)
  x=y-(fd.width / 2)
  
  x,y=listbox.clientToScreen(x,y)
  fd.top=y
  fd.left=x
end

local delayedResize

local function InheritanceResize(gbInheritance, now)
  if delayedResize==nil then
    local f=function()
      local i,x,y
      local width=gbInheritance.ClientWidth
      
      x=0
      y=0
      
      for i=0 , gbInheritance.ControlCount-1 do
        --the labels are in the order they get added to the groupbox
        local c=gbInheritance.Control[i]
        if (x~=0) and (x+c.Width>width) then --next line
          x=0
          y=y+c.height
        end
        
        c.Left=2+x
        c.Top=y
        
        
        x=x+c.Width+1
      end      
      delayedResize=nil      
    end
    
    if now then 
      f()
    else
      delayedResize=createTimer(100,f)
    end
  else
    --reset timer
    delayedResize.Enabled=false
    delayedResize.Enabled=true
  end
end

local function getMethodAddress(Method)
  if Method.Class.Image.Domain.Control==CONTROL_MONO then
    local address=mono_compile_method(Method.Handle)
    if address and address~=0 then 
      return address 
    else 
      return nil,trasnslate('Failure compiling the method')
    end
  else
    --the method already contains ILCode and NativeCode (requirying won't help until the collector is reloaded)
    if Method.NativeCode and Method.NativeCode~=0 then
      return Method.NativeCode
    elseif dotnetpipe and (tonumber(dotnetpipe.processid)==getOpenedProcessID()) then
      --print("getMethodAddress and dotnetpipe is valid")
      if Method.Class.Image.DotNetPipeModuleID==nil then
        --print("getting module id for "..Method.Class.Image.FileName)
        Method.Class.Image.DotNetPipeModuleID=dotnet_getModuleID(Method.Class.Image.FileName)
      end
      
      if Method.Class.Image.DotNetPipeModuleID then
        address=dotnet_getMethodEntryPoint(Method.Class.Image.DotNetPipeModuleID, Method.Handle)        
        if address==nil or address==0 then
          return nil, translate('Failure getting method address')
        end
        
        return address          
      else
        --print("No moduleid found")

        return nil, translate('Failure getting methodid for module named '..Method.Class.Image.FileName)                  
      end
    else
      return nil,'Not jitted and no dotnet pipe present' --not jitted yet and no dotnetpipe present
    end
  end
end

local function OpenAddressOfSelectedMethod(frmDotNetInfo)
  local Classs=frmDotNetInfo.CurrentlyDisplayedClass
  if Class==nill then return end
  
  local Method=Class.Methods[frmDotNetInfo.lvMethods.ItemIndex+1]
  if Method==nil then return end
  
  --print("Getting the entry point for "..Method.Name)
  local Address,ErrorMessage=getMethodAddress(Method)
 
  if (Address) then
    getMemoryViewForm().DisassemblerView.SelectedAddress=Address
    getMemoryViewForm().show()
  else   
    --todo:
    
    if (Method.Class.Image.Domain.Control~=CONTROL_MONO) then
      --it's not going to be the one you expect
      
      if (dotnetpipe==nil) and (messageDialog(translate('This method is currently not jitted. Do you wish to inject the .NET Control DLL into the target process to force it to generate an entry point for this method? (Does not work if the target is suspended)'), mtConfirmation, mbYes,mbNo)==mrYes) then
        --inject the control DLL
        LaunchDotNetInterface()    

        if dotnetpipe then
          
          Address,ErrorMessage=getMethodAddress(Method)   
          if Address then
            getMemoryViewForm().DisassemblerView.SelectedAddress=Address
            getMemoryViewForm().show()          
          else
            messageDialog(ErrorMessage, mtError, mbOK)
            return
          end
        end        
      else
        messageDialog(ErrorMessage, mtError, mbOK)
        return   
      end     
      
    else
      messageDialog(ErrorMessage, mtError, mbOK)
      return    
    end
  end
end


local function comboFieldBaseAddressChange(frmDotNetInfo, sender)
  local address=getAddressSafe(sender.Text)
  local Class=frmDotNetInfo.CurrentlyDisplayedClass
  
  if address then      
    frmDotNetInfo.lvFields.Columns[0].Caption=translate('Address')
    local i
    for i=0, frmDotNetInfo.lvFields.Items.Count-1 do
      local ci=frmDotNetInfo.lvFields.Items[i].Data
      if ci and ci>0 and ci<=#Class.Fields then
        local a=Class.Fields[ci].Offset+address
        frmDotNetInfo.lvFields.Items[i].Caption=string.format("%.8x ",a)
      end
    end
    frmDotNetInfo.tFieldValueUpdater.Enabled=true
    frmDotNetInfo.lvFields.Columns[3].Visible=true
    
    frmDotNetInfo.tFieldValueUpdater.OnTimer(frmDotNetInfo.tFieldValueUpdater)
  else
    --invalid
    frmDotNetInfo.lvFields.Columns[0].Caption=translate('Offset')
    
    
    local i
    for i=0, frmDotNetInfo.lvFields.Items.Count-1 do
      local ci=frmDotNetInfo.lvFields.Items[i].Data
      if ci and ci>0 and ci<=#Class.Fields then
        local a=Class.Fields[ci].Offset
        frmDotNetInfo.lvFields.Items[i].Caption=string.format("%.3x",a)
      end
    end  

    frmDotNetInfo.tFieldValueUpdater.Enabled=false
    frmDotNetInfo.lvFields.Columns[3].Visible=false
  end
end

local ELEMENT_TYPE_END        = 0x00       -- End of List
local ELEMENT_TYPE_VOID       = 0x01
local ELEMENT_TYPE_BOOLEAN    = 0x02
local ELEMENT_TYPE_CHAR       = 0x03
local ELEMENT_TYPE_I1         = 0x04
local ELEMENT_TYPE_U1         = 0x05
local ELEMENT_TYPE_I2         = 0x06
local ELEMENT_TYPE_U2         = 0x07
local ELEMENT_TYPE_I4         = 0x08
local ELEMENT_TYPE_U4         = 0x09
local ELEMENT_TYPE_I8         = 0x0a
local ELEMENT_TYPE_U8         = 0x0b
local ELEMENT_TYPE_R4         = 0x0c
local ELEMENT_TYPE_R8         = 0x0d
local ELEMENT_TYPE_STRING     = 0x0e
local ELEMENT_TYPE_PTR        = 0x0f   


local DotNetValueReaders={}
DotNetValueReaders[ELEMENT_TYPE_BOOLEAN]=function(address) 
  if readBytes(address,1)==0 then 
    return translate("False") 
  else 
    return translate("True") 
  end
end
  
DotNetValueReaders[ELEMENT_TYPE_CHAR]=function(address) 
  local b=readBytes(address,1) 
  local c=string.char(b)
  return c..' (#'..b..')'
end
  
DotNetValueReaders[ELEMENT_TYPE_I1]=function(address) 
  local v=readBytes(address,1) 
  if v and ((v & 0x80)~=0) then
    return v-0x100
  else
    return v
  end
end
DotNetValueReaders[ELEMENT_TYPE_U1]=function(address) return readBytes(address,1) end
DotNetValueReaders[ELEMENT_TYPE_I2]=function(address) return readSmallInteger(address,true) end 
DotNetValueReaders[ELEMENT_TYPE_U2]=function(address) return readSmallInteger(address) end 
DotNetValueReaders[ELEMENT_TYPE_I4]=function(address) return readInteger(address,true) end 
DotNetValueReaders[ELEMENT_TYPE_U4]=function(address) return readInteger(address) end 
DotNetValueReaders[ELEMENT_TYPE_I8]=function(address) return readQword(address) end 
DotNetValueReaders[ELEMENT_TYPE_U8]=DotNetValueReaders[MONO_TYPE_I8]
DotNetValueReaders[ELEMENT_TYPE_R4]=function(address) return readFloat(address) end 
DotNetValueReaders[ELEMENT_TYPE_R8]=function(address) return readDouble(address) end 
DotNetValueReaders[ELEMENT_TYPE_PTR]=function(address) 
  local v=readPointer(address)
  if v then
    return string.format("%.8x",v) 
  else
    return
  end 
end


local function FieldValueUpdaterTimer(frmDotNetInfo, sender)
  local i
  local address=getAddressSafe(frmDotNetInfo.comboFieldBaseAddress.Text)
  local Class=frmDotNetInfo.CurrentlyDisplayedClass
  if address and Class then  
    for i=0, frmDotNetInfo.lvFields.Items.Count-1 do
      local ci=frmDotNetInfo.lvFields.Items[i].Data
      if ci>0 and ci<=#Class.Fields then
        local a=address+Class.Fields[ci].Offset
        
        local reader=DotNetValueReaders[Class.Fields[ci].VarType]
        if reader==nil then
          reader=DotNetValueReaders[ELEMENT_TYPE_PTR]
        end
        
        local value=reader(a)
        if not value then
          value='?'          
        end
        if frmDotNetInfo.lvFields.Items[i].SubItems.Count<3 then
          frmDotNetInfo.lvFields.Items[i].SubItems.add(value)
        else
          frmDotNetInfo.lvFields.Items[i].SubItems[2]=value 
        end
        
              
        
        --printf("getting value for address %x which has type %d", a, Class.Fields[ci].VarType)
      end
    end
  end
end

local function btnLookupInstancesClick(frmDotNetInfo, sender)
  local Class=frmDotNetInfo.CurrentlyDisplayedClass
  if Class==nil then return end
  
  local scannerThread
  local f,l,pb,btnCancel
  local f=createForm(false)
  local results={}
  f.Caption="Scanning..."
  f.BorderIcons='[]'

  
 
  
  l=createLabel(f)
  l.Caption="Please wait while scanning for the list of instances"


  
  pb=createProgressBar(f)
  pb.BorderSpacing.Left=DPIMultiplier*1
  pb.BorderSpacing.Right=DPIMultiplier*1
  
  if Class.Image.Domain.Control~=CONTROL_MONO then --unknown time
    pb.Visible=false  
  end


  btnCancel=createButton(f)
  btnCancel.Caption=translate("Cancel")
  btnCancel.AutoSize=true




  btnCancel.BorderSpacing.Top=DPIMultiplier*10
  btnCancel.BorderSpacing.Bottom=DPIMultiplier*10

  l.AnchorSideTop.Control=f
  l.AnchorSideTop.Side=asrTop
  l.AnchorSideLeft.Control=f
  l.AnchorSideLeft.Side=asrLeft
  l.AnchorSideRight.Control=f
  l.AnchorSideRight.Side=asrRight
  l.Anchors='[akLeft, akRight, akTop]'

  pb.AnchorSideTop.Control=l
  pb.AnchorSideTop.Side=asrBottom
  pb.AnchorSideLeft.Control=f
  pb.AnchorSideLeft.Side=asrLeft
  pb.AnchorSideRight.Control=f
  pb.AnchorSideRight.Side=asrRight
  pb.Anchors='[akLeft, akRight, akTop]'


  btnCancel.AnchorSideTop.Control=pb
  btnCancel.AnchorSideTop.Side=asrBottom
  btnCancel.AnchorSideLeft.Control=f
  btnCancel.AnchorSideLeft.Side=asrCenter
  btnCancel.OnClick=function(s) f.close() end

  f.OnClose=function(sender)
    if scannerThread then --scannerThread is free on terminate, but before it does that it syncs and sets this var to nil
      scannerThread.terminate()
    end
    return caFree      
  end


  f.AutoSize=true
  f.Position=poScreenCenter
  
  --create the thread that will do the scan
  --it's possible the thread finishes before showmodal is called, but thanks to synchronize that won't happen
  scannerThread=createThread(function(t)
    t.Name='Instance Scanner'
    
    local r=getClassInstances(Class,pb)
    if r then
      local i
      for i=1,#r do
        results[i]=r[i]
      end
    end

    synchronize(function() 
      if not t.Terminated then 
        f.ModalResult=mrOK 
      end 
    end)
  end)
  
  
  if f.showModal()==mrOK then
    local i
    frmDotNetInfo.comboFieldBaseAddress.clear()
    for i=1,#results do
      frmDotNetInfo.comboFieldBaseAddress.Items.add(string.format("%.8x",results[i]))
    end    
  end
end



function miDotNetInfoClick(sender)
  
  --in case of a double case scenario where there's both .net and mono, go for net first if the user did not activate mono explicitly 
  if (DataSource.DotNetDataCollector==nil) or (CurrentProcess~=getOpenedProcessID) then  
    DataSource={}  
    DataSource.DotNetDataCollector=getDotNetDataCollector()    
  end
  
  if miMonoTopMenuItem and miMonoTopMenuItem.miMonoActivate.Visible and (monopipe==nil)  then
    if getDotNetDataCollector().Attached==false then --no .net and the user hasn't activated mono features. Do it for the user
      LaunchMonoDataCollector()  
    end
  end
  

  local frmDotNetInfo=createFormFromFile(getAutorunPath()..'forms'..pathsep..'DotNetInfo.frm')  
  local i
 
  --find an unused entry
  i=1
  while frmDotNetInfos[i] do i=i+1 end   

  frmDotNetInfos[i]=frmDotNetInfo
  frmDotNetInfo.Name="frmDotNetInfo"..i   
  frmDotNetInfo.Tag=i
  
  
  frmDotNetInfo.OnDestroy=function(f)
    f.SaveFormPosition({
      f.gbDomains.Width,    
      f.gbImages.Width,
      f.gbClasses.Width,
      f.gbStaticFields.Height,
      f.gbFields.Height,      
      
      --save the column widths
      f.lvStaticFields.Columns[0].Width,
      f.lvStaticFields.Columns[1].Width,
      f.lvStaticFields.Columns[2].Width,      
      f.lvStaticFields.Columns[3].Width,
      
      f.lvFields.Columns[0].Width,
      f.lvFields.Columns[1].Width,
      f.lvFields.Columns[2].Width,      
      f.lvFields.Columns[3].Width,
  
      f.lvMethods.Columns[0].Width,
      f.lvMethods.Columns[1].Width})
    
    CancelClassFetch(frmDotNetInfos[f.Tag])
    frmDotNetInfos[f.Tag]=nil
  end
  
  frmDotNetInfo.miImageFind.OnClick=function(f)
    FindInListBox(frmDotNetInfo.lbImages)
  end
  frmDotNetInfo.miImageFind.ShortCut=textToShortCut('Ctrl+F')
  
  frmDotNetInfo.miClassFind.OnClick=function(f)
    FindInListBox(frmDotNetInfo.lbClasses)
  end  
  frmDotNetInfo.miClassFind.ShortCut=textToShortCut('Ctrl+F')
  
  
  local formdata={}
  frmDotNetInfo.loadedFormPosition,formdata=frmDotNetInfo.LoadFormPosition()
  if frmDotNetInfo.loadedFormPosition then
    if #formdata>=5 then
      frmDotNetInfo.gbDomains.Width=formdata[1]
      frmDotNetInfo.gbImages.Width=formdata[2]
      frmDotNetInfo.gbClasses.Width=formdata[3]
      frmDotNetInfo.gbStaticFields.Height=formdata[4]
      frmDotNetInfo.gbFields.Height=formdata[5]
      
      if #formdata>=14 then      
        frmDotNetInfo.lvStaticFields.Columns[0].Width=formdata[6] or frmDotNetInfo.lvStaticFields.Columns[0].Width
        frmDotNetInfo.lvStaticFields.Columns[1].Width=formdata[7] or frmDotNetInfo.lvStaticFields.Columns[1].Width 
        frmDotNetInfo.lvStaticFields.Columns[2].Width=formdata[8] or frmDotNetInfo.lvStaticFields.Columns[2].Width     
        frmDotNetInfo.lvStaticFields.Columns[3].Width=formdata[9] or frmDotNetInfo.lvStaticFields.Columns[3].Width
        
        frmDotNetInfo.lvFields.Columns[0].Width=formdata[10] or frmDotNetInfo.lvFields.Columns[0].Width 
        frmDotNetInfo.lvFields.Columns[1].Width=formdata[11] or frmDotNetInfo.lvFields.Columns[1].Width 
        frmDotNetInfo.lvFields.Columns[2].Width=formdata[12] or frmDotNetInfo.lvFields.Columns[2].Width
        frmDotNetInfo.lvFields.Columns[3].Width=formdata[13] or frmDotNetInfo.lvFields.Columns[3].Width
    
        frmDotNetInfo.lvMethods.Columns[0].Width=formdata[14] or frmDotNetInfo.lvMethods.Columns[0].Width 
        frmDotNetInfo.lvMethods.Columns[1].Width=formdata[15] or frmDotNetInfo.lvMethods.Columns[1].Width
      end
      
    end   
  else
    --first run. 
    frmDotNetInfo.gbDomains.Width=DPIMultiplier*100
    frmDotNetInfo.gbImages.Width=DPIMultiplier*300
    frmDotNetInfo.gbClasses.Width=DPIMultiplier*200
    frmDotNetInfo.gbStaticFields.Height=DPIMultiplier*100
    frmDotNetInfo.gbFields.Height=DPIMultiplier*100
    frmDotNetInfo.Width=DPIMultiplier*1300
    frmDotNetInfo.Height=DPIMultiplier*700
    
    frmDotNetInfo.lvMethods.Columns[0].Width=frmDotNetInfo.Canvas.getTextWidth('somerandomnormalmethod')
    frmDotNetInfo.lvMethods.Columns[1].Width=frmDotNetInfo.Canvas.getTextWidth('(int a, float b, Object something)')    
    
    frmDotNetInfo.lvFields.Columns[0].Width=frmDotNetInfo.Canvas.getTextWidth(' FFFFFFFFFFFFFFFF ')
    frmDotNetInfo.lvFields.Columns[1].Width=frmDotNetInfo.lvMethods.Columns[0].Width
    frmDotNetInfo.lvStaticFields.Columns[0].Width=frmDotNetInfo.lvMethods.Columns[0].Width
   
    frmDotNetInfo.Position='poScreenCenter'
  end
  
  frmDotNetInfo.OnClose=function()
    return caFree 
  end
  
  --Domain box setup
  frmDotNetInfo.lbDomains.OnSelectionChange=function(sender) DomainSelectionChange(frmDotNetInfo, sender) end
  
  --Images box setup
  frmDotNetInfo.lbImages.OnSelectionChange=function(sender) ImageSelectionChange(frmDotNetInfo, sender) end
  
  --Classes box setup
  frmDotNetInfo.lbClasses.OnSelectionChange=function(sender) ClassSelectionChange(frmDotNetInfo, sender) end
  
  
  --Class info setup
  
  frmDotNetInfo.gbInheritance.OnResize=InheritanceResize
  
  frmDotNetInfo.miFindClass.OnClick=function() spawnDotNetSearchDialog(DataSource, frmDotNetInfo, 0) end
  frmDotNetInfo.miFindField.OnClick=function() spawnDotNetSearchDialog(DataSource, frmDotNetInfo, 1) end
  frmDotNetInfo.miFindMethod.OnClick=function() spawnDotNetSearchDialog(DataSource, frmDotNetInfo, 2) end
  
  frmDotNetInfo.miJitMethod.Default=true
  frmDotNetInfo.miJitMethod.OnClick=function() OpenAddressOfSelectedMethod(frmDotNetInfo) end
  frmDotNetInfo.lvMethods.OnDblClick=frmDotNetInfo.miJitMethod.OnClick
  
  frmDotNetInfo.comboFieldBaseAddress.OnChange=function(sender) comboFieldBaseAddressChange(frmDotNetInfo, sender) end
  frmDotNetInfo.btnLookupInstances.OnClick=function(sender) btnLookupInstancesClick(frmDotNetInfo, sender) end


  frmDotNetInfo.tFieldValueUpdater.OnTimer=function(t) FieldValueUpdaterTimer(frmDotNetInfo,t) end
    
  
  --Init
  
  
  if DataSource.Domains==nil then
    getDomains()
  end
  
  for i=1,#DataSource.Domains do
    local s=string.format("%x",DataSource.Domains[i].Handle)
    if DataSource.Domains[i].Name then
      s=s..' ( '..DataSource.Domains[i].Name..' ) '
    end
    
    frmDotNetInfo.lbDomains.Items.add(s)
  end
  
  if #DataSource.Domains==1 then
    frmDotNetInfo.lbDomains.ItemIndex=0
    frmDotNetInfo.gbDomains.Visible=false
    frmDotNetInfo.split1.Visible=false
  end
  
  
  if #DataSource.Domains==0 then
    DataSource={}
    CurrentProcess=nil --maybe later
    messageDialog(translate('No .NET info found'),mtError,mbOK)
    frmDotNetInfo.destroy()
  else
    frmDotNetInfo.show()  
  end
  
  _G.xxx=frmDotNetInfo
end

DataSource.getImages=getImages
DataSource.getDomains=getDomains
DataSource.getClasses=getClasses
DataSource.getClassFields=getClassFields
DataSource.getClassMethods=getClassMethods