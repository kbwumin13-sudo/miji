#!/usr/bin/env python3
"""Run a frozen labelled query set, compare binaries in alternating order, JSON output."""
import argparse,json,math,os,pathlib,statistics,subprocess
p=argparse.ArgumentParser();p.add_argument('--cli',action='append',required=True,help='label=/absolute/cli');p.add_argument('--database',required=True);p.add_argument('--queries',required=True);p.add_argument('--output',required=True);p.add_argument('--rounds',type=int,default=6);p.add_argument('--limit',type=int,default=500);a=p.parse_args()
suite=json.load(open(a.queries));binaries=[s.split('=',1) for s in a.cli];rows=[]
env=dict(os.environ,MallocSpaceEfficient='1')
for turn in range(a.rounds):
    for q in suite['queries']:
        order=binaries if turn%2==0 else list(reversed(binaries))
        for label,cli in order:
            cmd=[cli,'quality-search','--database',a.database,'--query',q['query'],'--scope',q['scope'],'--limit',str(a.limit),'--trace']
            for k,v in q.get('filters',{}).items():
                flag={'onlineOnly':'--online-only','rootID':'--root-id','kind':'--kind','sort':'--sort'}[k]
                cmd += [flag] if v is True else [flag,str(v)]
            value=json.loads(subprocess.check_output(cmd,env=env))
            paths=[h['path'] for h in value['hits']]
            unknown=set(paths)-q['labels'].keys()
            if unknown: raise RuntimeError(f'unlabelled results: {unknown}')
            families=suite['families']; seen=set();gains=[]
            for path in paths[:10]:
                family=families[path];gains.append(0 if family in seen else (2**q['labels'][path]-1));seen.add(family)
            ideal={}
            for path,grade in q['labels'].items():ideal[families[path]]=max(ideal.get(families[path],0),2**grade-1)
            dcg=lambda xs:sum(g/math.log2(i+2) for i,g in enumerate(xs))
            denominator=dcg(sorted(ideal.values(),reverse=True)[:10])
            ranks=[i+1 for i,path in enumerate(paths) if q['labels'][path]==3]
            candidate=value['metrics']['candidateOrder']
            target_ord=[candidate.index(t)+1 for t in q['targets'] if t in candidate]
            value.update(label=label,id=q['id'],turn=turn,holdout=q['holdout'],task=q['task'],
                first_rank=min(ranks) if ranks else None,success5=bool(ranks and min(ranks)<=5),
                known_target_coverage=sum(t in candidate or t in paths for t in q['targets'])/len(q['targets']),
                target_candidate_ordinal=target_ord,ndcg10=dcg(gains)/denominator if denominator else None)
            rows.append(value)
pathlib.Path(a.output).write_text(json.dumps(dict(database=a.database,rounds=a.rounds,limit=a.limit,rows=rows),ensure_ascii=False,indent=2))
def pct(values,p):
    s=sorted(values);return s[min(len(s)-1,math.ceil(len(s)*p)-1)]
for label,_ in binaries:
    rs=[r for r in rows if r['label']==label]
    # First invocation per query is separated from later process launches (OS cache remains warm).
    warm=[r for r in rs if r['turn']>0]
    print(json.dumps(dict(label=label,success5=statistics.mean(r['success5'] for r in rs),coverage=statistics.mean(r['known_target_coverage'] for r in rs),p50_ms=statistics.median(r['final_ms'] for r in warm),p95_ms=pct([r['final_ms'] for r in warm],.95)),ensure_ascii=False))
