IMPORT ML_Core;
IMPORT ML_Core.Types AS Types;
IMPORT STD.system.Thorlib;
IMPORT Files;

//Load raw data
//**make sure the id of the data is sequential starting from 1
ds := Files.trainRecs;
//Add ID field and transform
//the raw data to NumericField type
ML_Core.AppendSeqID(ds, id, recs);
ML_Core.ToField(recs, recsNF);

//Evenly distribute the data
Xnf1 := DISTRIBUTE(recsNF, id);
//Transform to 1_stage1
X0 := PROJECT(Xnf1, TRANSFORM(
                              Files.l_stage1,
                              SELF.fields := [LEFT.value],
                              SELF.nodeId := Thorlib.node(),
                              SELF := LEFT),
                              LOCAL);
X1 := SORT(X0, wi, id, number, LOCAL);
X2 := ROLLUP(X1, TRANSFORM(
                            Files.l_stage1,
                            SELF.fields := LEFT.fields + RIGHT.fields,
                            SELF := LEFT),
                            wi, id,
                            LOCAL);
//Transform to l_stage2
X3 := PROJECT(X2, TRANSFORM(
                            Files.l_stage2,
                            SELF.parentID := LEFT.id,
                            SELF := LEFT),
                            LOCAL);

DATASET(Files.l_stage3) locDBSCAN(DATASET(Files.l_stage2) dsIn, //distributed data from stage 1
                                  REAL8 eps,   //distance threshold
                                  UNSIGNED minPts, //the minimum number of points required to form a cluster,
                                  UNSIGNED4 localNode = Thorlib.node()
                                  ) := EMBED(C++ : activity)

#include <iostream>
#include <bits/stdc++.h>
#include <cmath>

using namespace std;

struct dataRecord{
  uint16_t wi;
  unsigned long long id;
  unsigned long long parentId;
  unsigned long long nodeId;
  bool isAllFields;
  uint32_t lenFields;
  vector<double> fields;
  bool if_local;
  bool if_core;
};

vector<dataRecord> readDS(const void *s, uint32_t len){
  vector<dataRecord> ret;
  char* p = (char*)s;
  while(len){
    dataRecord temp;
    temp.wi = *((uint16_t*)p); p += sizeof(uint16_t);
    temp.id = *((unsigned long long*)p); p += sizeof(unsigned long long);
    temp.parentId = *((unsigned long long*)p); p += sizeof(unsigned long long);
    temp.nodeId = *((unsigned long long*)p); p += sizeof(unsigned long long);
    temp.isAllFields = *((bool*)p); p += sizeof(bool);
    temp.lenFields = *((uint32_t*)p); p += sizeof(uint32_t);
    for(int i=0; i<temp.lenFields/sizeof(float); ++i){
      double f = (double)(*((float*)p)); p += sizeof(float);
      temp.fields.push_back(f);
    }
    temp.if_local = *((bool*)p); p += sizeof(bool);
    temp.if_core = *((bool*)p); p += sizeof(bool);
    ret.push_back(temp);
    int sizeStruct = sizeof(uint16_t) + 3*sizeof(unsigned long long) +
                    3*sizeof(bool) + sizeof(uint32_t) + temp.lenFields;
    len -= sizeStruct;
  }
  return ret;
}

struct retRecord{
  uint16_t wi;
  unsigned long long id;
  unsigned long long parentId;
  unsigned long long nodeId;
  bool if_local;
  bool if_core;
};

void* writeDS(vector<retRecord> ds, uint32_t& len){
  uint32_t lenRec = sizeof(uint16_t) + 3*sizeof(unsigned long long) + 2*sizeof(bool);
  uint32_t totLen = ds.size() * lenRec;
  len = totLen;
  void* r = rtlMalloc(totLen);
  char* p = (char*)r;
  for(uint i=0; i<ds.size(); ++i){
    *((uint16_t*)p) = ds[i].wi; p += sizeof(uint16_t);
    *((unsigned long long*)p) = ds[i].id; p += sizeof(unsigned long long);
    *((unsigned long long*)p) = ds[i].parentId; p += sizeof(unsigned long long);
    *((unsigned long long*)p) = ds[i].nodeId; p += sizeof(unsigned long long);
    *((bool*)p) = ds[i].if_local; p += sizeof(bool);
    *((bool*)p) = ds[i].if_core; p += sizeof(bool);
  }
  return r;
}

struct node
{
  int data;
  node* parent=NULL;
  vector<node *> child;
};

struct row
{
    vector<double> fields;
    struct node id;
    int actual_id;
};

typedef struct node* Node;
typedef struct row* Row;

Node newNode(int data){
  Node n=new struct node;
  n->data=data;
    return n;	
}

Node find(Node y){

    if(y==NULL){
            return NULL;
  }
  return (y->parent)==NULL?y:find(y->parent);
}


// returning the root of the tree
Node unionOp(Node x,Node y)
{

  // cout<<"INSIDE "<<x->data<<"INSDIE";
  if(find(y)==y)
  {
    if(x->data>y->data){
    (x->child).push_back(y);
    y->parent=x;     
    }
    else
    {
      (y->child).push_back(x);
    x->parent=y; 
    }
    
    return find(x);
  }
  else if(find(x)==find(y)){  
        return find(x);
  }
    else
  {
      if(find(x)->data>find(y)->data){
        (find(x)->child).push_back(find(y));
        (find(y)->parent)=find(x);
      return find(x);
    
    }
      else{
        (find(y)->child).push_back(find(x));
        (find(x)->parent)=find(y);
        return find(y);
    }
      
  }


}

double euclidean(Row row1,Row row2){
    double ans=0;
    int M=row1->fields.size();
    
    for(int i=0;i<M;i++)
    ans+=((row1->fields[i])-(row2->fields[i]))*((row1->fields[i])-(row2->fields[i]));

    return sqrt(ans);
}

vector<int> visited;
vector<int> core;

Row newRow( int id){
    Row newrow=new struct row;
    newrow->id.data=id;
    return newrow;
}

vector<Row> initialise(vector<vector<double>> dataset){
    int N = dataset.size();
    int M = dataset[0].size();
    vector<Row> data;
    visited.resize(N);
    core.resize(N);

    for(int i=0;i<N;i++){
    visited.push_back(0);
    core.push_back(0);
    }

    for(int i=0;i<N;i++){

        //initially each node is pointing to itself
        
        Row r= newRow(i);
        r->fields.resize(M);
        
        for(int j=0;j<M;j++){
            r->fields[j]=dataset[i][j];
        }
        r->actual_id=i;
        data.push_back(r);
    }
    return data;
}

vector<Row> getNeighrestNeighbours(vector<Row> dataset, Row row, double eps, vector<uint16_t> wis, uint16_t wi){
    vector<Row> neighbours;
    for(int i=0;i<dataset.size();i++){
        if(dataset[i]==row)
        continue;

        if(wis[i] != wi)
        continue;

        double dist = euclidean(dataset[i],row);
        if(dist<=eps){
            neighbours.push_back(dataset[i]);
        }
    }
    return neighbours;
}

vector<Row> dbscan(vector<vector<double>> dataset,int minpoints,double eps,vector<bool> ifLocal, vector<uint16_t> wis, vector<bool> &isModified){
    vector<Row> transdataset=initialise(dataset);
    vector<Row> neighs;
    Node temp;
    int temp1;
    for(int ro=0;ro<transdataset.size();ro++){
        cout<<"Processing"<<ro<<endl;
        
        if(!ifLocal[ro]) continue;

        neighs=getNeighrestNeighbours(transdataset,transdataset[ro],eps,wis,wis[ro]);
        
        if(neighs.size()>=minpoints){
            core[ro]=1;
            
            for(int neigh=0;neigh<neighs.size();neigh++){
                int neighId = neighs[neigh]->actual_id;
                isModified[neighId] = true;
                if(ifLocal[neighId]){
                    // Local neighbour
                    temp1=core[neighId];
                    if(temp1)
                    {
            
                        //modify parent id's
                        temp=unionOp(&transdataset[ro]->id,&neighs[neigh]->id);
                        cout<<"\nThe parent is "<<temp->data<<endl;
                    }
                    else
                    {
                        if(!visited[neighId]){
                            visited[neighId]=1;
                            // cout<<" Trying union for "<<transdataset[ro]->id.data<<" and "<<neighs[neigh]->id.data<<endl;
                        temp=unionOp(&transdataset[ro]->id,&neighs[neigh]->id);

                        cout<<"\nThe parent is "<<temp->data<<endl;
                        }
                    }
                } else {
                    // Remote neighbour
                    vector<Row> tempNeighs = getNeighrestNeighbours(transdataset,transdataset[neighId],eps,wis,wis[neighId]);
                    if(tempNeighs.size() >= minpoints)
                        core[neighId] = 1;
                    unionOp(&transdataset[ro]->id,&neighs[neigh]->id);
                }
            }
        }
    }
    return transdataset;
}

#body

unsigned long long lnode = localnode;

vector<vector<double>> dataset;
                              
vector<dataRecord> ds = readDS(dsin, lenDsin);
vector<bool> ifLocal;
vector<uint16_t> wis;
vector<bool> isModified;

for(uint i=0; i<ds.size(); ++i){
  dataset.push_back(ds[i].fields);
  ifLocal.push_back(lnode == ds[i].nodeId);
  isModified.push_back(lnode == ds[i].nodeId);
  wis.push_back(ds[i].wi);
}

vector<Row> out_data= dbscan(dataset,minpts,eps,ifLocal,wis,isModified);

vector<retRecord> retDs;

for(uint i=0;i<out_data.size();i++){
  if(!isModified[i]) continue;
  Node dat=find(&out_data[i]->id);
  retRecord temp;
  temp.wi = ds[i].wi;
  temp.id = ds[i].id;
  temp.parentId = ds[dat->data].id;
  temp.nodeId = lnode;
  temp.if_local = ifLocal[i];
  temp.if_core = core[i];
  retDs.push_back(temp);
}

__result = writeDS(retDs, __lenResult);

ENDEMBED;

OUTPUT(locDBSCAN(X3,0.5,5));
