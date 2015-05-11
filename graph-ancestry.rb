require 'optparse'
require 'rugged'
require 'set'
require 'pry'

class Array
  def abbreviated_join(separator='', collapse_after: 4, end_length: 1, middle: nil)
    return join(separator) if size <= collapse_after
    middle = "(#{size-2*end_length} omitted)" if middle.nil?
    xs = (size > 2*end_length+1) ? self[0...end_length] + [middle] + self[-end_length..-1] : self
    xs.join separator
  end
end


class Rugged::Commit
  def eql?(other)
    oid == other.oid
  end

  def hash
    oid.hash
  end

  def authors_initials
    match = message.match /(?<initials>\w{2,3}(\/\(?\w{2,3}\)?)*) ?-/
    if match
      match['initials'].split('/').map{|initials| initials.delete '()'}
    else
      [author[:name].downcase.split.map{|word| word[0]}.join]
    end
  end
end

class Node
  attr_accessor :value, :parents, :children
  def initialize(value, parents: Set.new, children: Set.new)
    @value = value
    @parents = Set.new
    @children = Set.new

    parents.each {|p| add_parent p}
    children.each {|c| add_child c}
  end

  def add_parent(parent)
    raise TypeError unless parent.is_a? Node
    parents.add parent
    parent.children.add self
  end

  def remove_parent(parent)
    parents.delete parent
    parent.children.delete self
  end

  def parent?(parent)
    parents.include? parent
  end

  def add_child(child)
    raise TypeError unless child.is_a? Node
    children.add child
    child.parents.add self
  end

  def remove_child(child)
    children.delete child
    child.parents.delete self
  end

  def child?(child)
    children.include? child
  end
end

class Graph
  attr_accessor :nodes

  def initialize(nodes=Set.new)
    @nodes = nodes
    integrity_check
  end

  def dup
    result = Graph.new
    analogues = {}
    nodes.each do |node|
      analogues[node] = result.add_node(node.value)
    end

    analogues.each do |ours, analogue|
      ours.parents.each do |our_parent|
        analogue_parent = analogues[our_parent]
        analogue.add_parent analogue_parent
      end
    end
    result
  end

  def add_node(value, parents: Set.new, children: Set.new)
    node = Node.new(value, parents: parents, children: children)
    nodes.add node
    # integrity_check
    node
  end

  def delete_node(node)
    node.parents.each {|p| node.remove_parent(p)}
    node.children.each {|c| node.remove_child(c)}
    nodes.delete node
    # integrity_check
  end

  def contract!(run_finder: RunFinder.new)
    result = Graph.new
    unaccounted_for = @nodes.dup

    until unaccounted_for.empty?
      run, parents, children = run_finder.find_run(unaccounted_for.first)
      add_node(run, parents: parents, children: children)
      run.each do |victim|
        unaccounted_for.delete victim
        delete_node victim
      end
    end

    integrity_check

    self
  end

  def contract(*args)
    result = self.dup
    result.contract!(*args)
  end

  def to_dot(styler, cluster: nil)
    lines = ['digraph Repo {']

    nodes_to_declare = nodes.dup

    unless cluster.nil?
      lines << "subgraph cluster_fun_times {"
      lines << 'label = "MASTER CHAIN";'

      cluster.each do |node|
        lines << "_#{node.__id__} [#{styler.style(node)}];"
      end
      nodes_to_declare -= cluster

      lines << "}"
    end

    nodes_to_declare.each do |node|
        lines << "_#{node.__id__} [#{styler.style(node)}];"
    end
    nodes_to_declare -= nodes_to_declare

    nodes.each do |node|
      node.parents.each do |parent|
        lines << "_#{node.__id__} -> _#{parent.__id__};"
      end
    end

    lines << '}'

    lines.join("\n")
  end

  def integrity_check
    nodes_traced = Set.new

    nodes.each do |node|
      nodes_traced.add node

      node.parents.each do |parent|
        nodes_traced.add parent
        binding.pry unless parent.child? node
      end

      node.children.each do |child|
        nodes_traced.add child
        binding.pry unless child.parent? node
      end
    end

    binding.pry unless nodes_traced == nodes
  end
end

class ValueExistsException < Exception; end
module UniqueNodeValues
  def values_nodes
    if @values_nodes.nil?
      @values_nodes = {}
      nodes.each {|n| @values_nodes[n.value] = n}
    end
    @values_nodes
  end

  def add_node(value, parents: Set.new, children: Set.new)
    if values_nodes.key? value
      raise ValueExistsException.new
    end
    new_node = super
    values_nodes[value] = new_node
    new_node
  end

  def add_node?(value, parents: Set.new, children: Set.new)
    add_node(value, parents: parents, children: children)
  rescue ValueExistsException
    values_nodes[value]
  end

  def delete_node(node)
    values_nodes.delete node.value
    super
  end
end


class PartialCommitGraph < Graph

  include UniqueNodeValues

  attr_accessor :repo, :master_chain

  def initialize(repo, *args)
    super(*args)
    @repo = repo
    @master_chain = [add_node((repo.branches['origin/master'] || repo.branches['master']).target)]

    master_commit = master_chain.first.value
    def master_commit.dot_node_label
      'master'
    end
  end

  def add_commit_and_ancestors(commit)
    node = add_node? commit
    extend_master_chain_until commit.time
    return node if master_chain.include? node

    commit.parents.each do |parent_commit|
      parent = add_commit_and_ancestors(parent_commit)
      node.add_parent parent
    end
    node
  end

  def extend_master_chain_until(time)
    extend_master_chain until master_chain.last.value.time <= time
  end

  def extend_master_chain
    old_root = master_chain.last
    old_root_commit = old_root.value
    new_root_commit = old_root_commit.parents.first
    new_root = add_node? new_root_commit, children: [old_root]
    master_chain << new_root
  end

  def contract!(*args)
    raise TypeError('unable to do in-place contraction of PartialCommitGraph')
  end
end



def denodify(x)
  result = x
  result = result.value while result.is_a? Node
  result = result.map{|y| denodify(y)} if result.is_a? Array
  result
end

class Styler
  attr_accessor :branches
  def initialize(branches)
    @branches = branches
  end

  def style(x)
    x = denodify x
    attributes = {label: label(x).inspect}
    if x.is_a?(Array) && !x.empty? && branches.map(&:target).include?(x.first)
      attributes[:style] = 'filled'
    end
    segments = attributes.map{|k, v| "#{k}=#{v}"}
    segments.join ', '
  end

  def label(x)
    if x.is_a? Rugged::Commit
      label_commit x
    elsif x.is_a? Array
      label_array x
    elsif x.is_a? String
      label_string x
    else
      x.inspect
    end
  end

  def label_string(s)
    s
  end

  def label_commit(commit, initials: true)
    branches.each do |branch|
      return branch.name if branch.target == commit
    end
    result = "#{commit.oid.slice(0, 7)}"
    result += " #{commit.authors_initials.abbreviated_join '/', middle:'...'}" if initials
    result
  end

  def label_array(array)
    if array.empty?
      '[]'
    elsif array.one?
      label array.first
    elsif array.all? {|elem| elem.is_a? Rugged::Commit}
      label_commits array
    else
      array.map{|x| label x}.abbreviated_join "\n"
    end
  end

  def label_commits(commits)
    initials = commits.map(&:authors_initials).flatten.uniq.abbreviated_join '/', middle: '...'
    "#{label_commit(commits.first, initials:false)}..#{label_commit(commits.last, initials:false)}\n(#{commits.size} commits)\n#{initials}"
  end
end

class RunFinder

  attr_accessor :interesting_values
  
  def initialize(interesting_values: [])
    @interesting_values = interesting_values
  end

  def find_run(node)
    return [[node], node.parents, node.children] if interesting? node
    # binding.pry
    run = [node]
    run.insert(0, run.first.parents.first) while run.first.parents.one? && !interesting?(run.first.parents.first)
    run << run.last.children.first while run.last.children.one? && !interesting?(run.last.children.first)
    [run, run.first.parents, run.last.children]
  end

  def interesting?(node)
    interesting_values.include?(node.value) || !node.parents.one? || !node.children.one?
  end
end


require 'optparse'

args = {directory: '.'}
OptionParser.new do |opts|
  opts.banner = "Usage: graph-ancestry.rb [options] BRANCH ..."

  opts.on('--contract', 'Compress runs of commits with no forks/merges') do |contract|
    args[:contract?] = contract
  end

  opts.on('--keep-old-branches', 'do not throw out branches over 2 months old') do |keep_old_branches|
    args[:keep_old_branches?] = keep_old_branches
  end

  opts.on('-d', '--directory DIR', "git repository root (default #{args[:directory]} or ancestor)") do |dir|
    args[:directory] = dir
  end
end.parse!

args[:branch_patterns] = ARGV

repo = Rugged::Repository.new(args[:directory])

branches = []
args[:branch_patterns].each do |pattern|
  matching_branches = repo.branches.select{|b| b.name.match pattern}
  STDERR.puts "Warning: no branches match #{pattern}" if matching_branches.empty?
  branches += matching_branches
end

unless args[:keep_old_branches?]
  discard = branches.select{|b| b.target.time < Time.now - 60*60*24*30}

  unless discard.empty?
    STDERR.puts "Discarded #{discard.size} branches for being too old:"
    discard.each {|b| STDERR.puts "  #{b.target.time.strftime('%Y-%m-%d')} - #{b.name}"}
  end

  branches -= discard
end


STDERR.puts "Continuing with #{branches.size} branches:"
branches.each do |b|
  STDERR.puts "  #{b.name}"
end


branches << (repo.branches['origin/master'] || repo.branches['master'])

graph = PartialCommitGraph.new(repo)
branches.each {|b| graph.add_commit_and_ancestors(b.target)}

final_graph = graph.contract(run_finder: RunFinder.new(interesting_values: branches.map(&:target)))

styler = Styler.new(branches)

# binding.pry
puts final_graph.to_dot(styler, cluster: final_graph.nodes.select{|n| graph.master_chain.map(&:value).include? n.value.first.value})
